{-# LANGUAGE OverloadedStrings, GeneralizedNewtypeDeriving #-}
-- | It should be noted that most of the code snippets below depend on the
-- OverloadedStrings language pragma.
module Web.Scotty
    ( -- * scotty-to-WAI
      scotty, scottyApp
      -- * Defining Middleware and Routes
      --
      -- | 'Middleware' and routes are run in the order in which they
      -- are defined. All middleware is run first, followed by the first
      -- route that matches. If no route matches, a 404 response is given.
    , middleware, get, post, put, delete, addroute
      -- * Defining Actions
      -- ** Accessing the Request, Captures, and Query Parameters
    , request, param
      -- ** Modifying the Response and Redirecting
    , status, header, redirect
      -- ** Setting Response
      --
      -- | Note: only one of these should be present in any given route
      -- definition, as they completely replace the current 'Response' body.
    , text, html, file, json
      -- ** Exceptions
    , raise, rescue, continue
      -- * Types
    , ScottyM, ActionM
    ) where

import Blaze.ByteString.Builder (fromByteString, fromLazyByteString)

import Control.Applicative
import Control.Monad.Error
import Control.Monad.Reader
import qualified Control.Monad.State as MS

import qualified Data.Aeson as A
import qualified Data.ByteString.Char8 as B
import qualified Data.CaseInsensitive as CI
import Data.Default (Default, def)
import Data.Enumerator.List (consume)
import Data.Enumerator.Internal (Iteratee)
import Data.Maybe (fromMaybe)
import Data.Monoid (mconcat)
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.Encoding as E

import Network.HTTP.Types
import Network.Wai
import Network.Wai.Handler.Warp (Port, run)

import Web.Scotty.Util

data ScottyState = ScottyState {
        middlewares :: [Middleware],
        routes :: [Middleware]
    }

instance Default ScottyState where
    def = ScottyState [] []

newtype ScottyM a = S { runS :: MS.StateT ScottyState IO a }
    deriving (Monad, MonadIO, Functor, MS.MonadState ScottyState)

-- | Run a scotty application using the warp server.
scotty :: Port -> ScottyM () -> IO ()
scotty p s = putStrLn "Setting phasers to stun... (ctrl-c to quit)" >> (run p =<< scottyApp s)

-- | Turn a scotty application into a WAI 'Application', which can be
-- run with any WAI handler.
scottyApp :: ScottyM () -> IO Application
scottyApp defs = do
    s <- MS.execStateT (runS defs) def
    return $ foldl (flip ($)) notFoundApp $ routes s ++ middlewares s

notFoundApp :: Application
notFoundApp _ = return $ ResponseBuilder status404 [("Content-Type","text/html")]
                       $ fromByteString "<h1>404: File Not Found!</h1>"

-- | Use given middleware. Middleware is nested such that the first declared
-- is the outermost middleware (it has first dibs on the request and last action
-- on the response). Every middleware is run on each request.
middleware :: Middleware -> ScottyM ()
middleware m = MS.modify (\ (ScottyState ms rs) -> ScottyState (m:ms) rs)

type Param = (T.Text, T.Text)

data ActionError = Redirect T.Text
                 | ActionError T.Text
                 | Continue
    deriving (Eq,Show)

instance Error ActionError where
    strMsg = ActionError . T.pack

newtype ActionM a = AM { runAM :: ErrorT ActionError (ReaderT (Request,[Param]) (MS.StateT Response IO)) a }
    deriving ( Monad, MonadIO, Functor
             , MonadReader (Request,[Param]), MS.MonadState Response, MonadError ActionError)

-- Nothing indicates route failed (due to Continue) and pattern matching should continue.
-- Just indicates a successful response.
runAction :: [Param] -> ActionM () -> Request -> Iteratee B.ByteString IO (Maybe Response)
runAction ps action req = do
    (e,r) <- lift $ flip MS.runStateT def
                  $ flip runReaderT (req,ps)
                  $ runErrorT
                  $ runAM
                  $ action `catchError` defaultHandler
    return $ either (const Nothing) (const $ Just r) e

defaultHandler :: ActionError -> ActionM ()
defaultHandler (Redirect url) = do
    status status302
    header "Location" url
defaultHandler (ActionError msg) = do
    status status500
    html $ mconcat ["<h1>500 Internal Server Error</h1>", msg]
defaultHandler Continue = continue

-- | Throw an exception, which can be caught with 'rescue'. Uncaught exceptions
-- turn into HTTP 500 responses.
raise :: T.Text -> ActionM a
raise = throwError . ActionError

-- | Abort execution of this action and continue pattern matching routes.
-- Like an exception, any code after 'continue' is not executed.
--
-- As an example, these two routes overlap. The only way the second one will
-- ever run is if the first one calls 'continue'.
--
-- > get "/foo/:number" $ do
-- >   n <- param "number"
-- >   unless (all isDigit n) $ continue
-- >   text "a number"
-- >
-- > get "/foo/:bar" $ do
-- >   bar <- param "bar"
-- >   text "not a number"
continue :: ActionM a
continue = throwError Continue

-- | Catch an exception thrown by 'raise'.
--
-- > raise "just kidding" `rescue` (\msg -> text msg)
rescue :: ActionM a -> (T.Text -> ActionM a) -> ActionM a
rescue action handler = catchError action $ \e -> case e of
    ActionError msg -> handler msg  -- handle errors
    other           -> throwError other -- rethrow redirects and continues

-- | Redirect to given URL. Like throwing an uncatchable exception. Any code after the call to redirect
-- will not be run.
--
-- > redirect "http://www.google.com"
--
-- OR
--
-- > redirect "/foo/bar"
redirect :: T.Text -> ActionM ()
redirect = throwError . Redirect

-- | Get the 'Request' object.
request :: ActionM Request
request = fst <$> ask

-- | Get a parameter. First looks in captures, then form data, then query parameters. Raises
-- an exception which can be caught by 'rescue' if parameter is not found.
param :: T.Text -> ActionM T.Text
param k = do
    val <- lookup k <$> snd <$> ask
    maybe (raise $ mconcat ["Param: ", k, " not found!"]) return val

-- | get = addroute 'GET'
get :: T.Text -> ActionM () -> ScottyM ()
get    = addroute GET

-- | post = addroute 'POST'
post :: T.Text -> ActionM () -> ScottyM ()
post   = addroute POST

-- | put = addroute 'PUT'
put :: T.Text -> ActionM () -> ScottyM ()
put    = addroute PUT

-- | delete = addroute 'DELETE'
delete :: T.Text -> ActionM () -> ScottyM ()
delete = addroute DELETE

-- | Define a route with a 'StdMethod', 'T.Text' value representing the path spec,
-- and a body ('ActionM') which modifies the response.
--
-- > addroute GET "/" $ text "beam me up!"
--
-- The path spec can include values starting with a colon, which are interpreted
-- as /captures/. These are named wildcards that can be looked up with 'param'.
--
-- > addroute GET "/foo/:bar" $ do
-- >     v <- param "bar"
-- >     text v
--
-- >>> curl http://localhost:3000/foo/something
-- something
addroute :: StdMethod -> T.Text -> ActionM () -> ScottyM ()
addroute method path action = MS.modify (\ (ScottyState ms rs) -> ScottyState ms (r:rs))
    where r = route method withSlash action
          withSlash = case T.uncons path of
                        Just ('/',_) -> path
                        _            -> T.cons '/' path

-- todo: wildcards?
route :: StdMethod -> T.Text -> ActionM () -> Middleware
route method path action app req =
    if Right method == parseMethod (requestMethod req)
    then case matchRoute path (strictByteStringToLazyText $ rawPathInfo req) of
            Just params -> do
                formParams <- parseFormData method req
                res <- runAction (addQueryParams req $ params ++ formParams) action req
                maybe tryNext return res
            Nothing -> tryNext
    else tryNext
  where tryNext = app req

matchRoute :: T.Text -> T.Text -> Maybe [Param]
matchRoute pat req = go (T.split (=='/') pat) (T.split (=='/') req) []
    where go [] [] ps = Just ps -- request string and pattern match!
          go [] r  ps | T.null (mconcat r)  = Just ps -- in case request has trailing slashes
                      | otherwise           = Nothing -- request string is longer than pattern
          go p  [] ps | T.null (mconcat p)  = Just ps -- in case pattern has trailing slashes
                      | otherwise           = Nothing -- request string is not long enough
          go (p:ps) (r:rs) prs | p == r          = go ps rs prs -- equal literals, keeping checking
                               | T.null p        = Nothing      -- p is null, but r is not, fail
                               | T.head p == ':' = go ps rs $ (T.tail p, r) : prs
                                                                -- p is a capture, add to params
                               | otherwise       = Nothing      -- both literals, but unequal, fail

-- TODO: this is probably better implemented as middleware
parseFormData :: StdMethod -> Request -> Iteratee B.ByteString IO [Param]
parseFormData POST req = case lookup "Content-Type" [(CI.mk k, CI.mk v) | (k,v) <- requestHeaders req] of
                            Just "application/x-www-form-urlencoded" -> do reqBody <- mconcat <$> consume
                                                                           return $ parseEncodedParams reqBody []
                            _ -> do lift $ putStrLn "Unsupported form data encoding. TODO: Fix"
                                    return []
parseFormData _    _   = return []

addQueryParams :: Request -> [Param] -> [Param]
addQueryParams = parseEncodedParams . rawQueryString

parseEncodedParams :: B.ByteString -> [Param] -> [Param]
parseEncodedParams bs = (++ [ (T.fromStrict k, T.fromStrict $ fromMaybe "" v) | (k,v) <- parseQueryText bs ])

-- | Set the HTTP response status. Default is 200.
status :: Status -> ActionM ()
status = MS.modify . setStatus

-- | Set one of the response headers. Will override any previously set value for that header.
-- Header names are case-insensitive.
header :: T.Text -> T.Text -> ActionM ()
header k v = MS.modify $ setHeader (CI.mk $ lazyTextToStrictByteString k, lazyTextToStrictByteString v)

-- | Set the body of the response to the given 'T.Text' value. Also sets \"Content-Type\"
-- header to \"text/plain\".
text :: T.Text -> ActionM ()
text t = do
    header "Content-Type" "text/plain"
    MS.modify $ setContent $ Left $ fromLazyByteString $ E.encodeUtf8 t

-- | Set the body of the response to the given 'T.Text' value. Also sets \"Content-Type\"
-- header to \"text/html\".
html :: T.Text -> ActionM ()
html t = do
    header "Content-Type" "text/html"
    MS.modify $ setContent $ Left $ fromLazyByteString $ E.encodeUtf8 t

-- | Send a file as the response. Doesn't set the \"Content-Type\" header, so you probably
-- want to do that on your own with 'header'.
file :: FilePath -> ActionM ()
file = MS.modify . setContent . Right

-- | Set the body of the response to the JSON encoding of the given value. Also sets \"Content-Type\"
-- header to \"application/json\".
json :: (A.ToJSON a) => a -> ActionM ()
json v = do
    header "Content-Type" "application/json"
    MS.modify $ setContent $ Left $ fromLazyByteString $ A.encode v
