{-|
Module      : WebApi.Client
License     : BSD3
Stability   : experimental

Provides a client for a web api for a given contract.
-}

{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DefaultSignatures     #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# LANGUAGE CPP                   #-}
module WebApi.Client
       (
         -- * Client related functions
         client
       , fromClientResponse
       , toClientRequest
       , link

         -- * Types
       , ClientSettings (..)
       , UnknownClientException

         -- * Connection manager
       , HC.Manager
       , HC.newManager
       , HC.closeManager
       , HC.withManager
       , HC.HasHttpManager (..)

         -- ** Connection manager settings
       , HC.ManagerSettings
       , HC.defaultManagerSettings
       , HC.tlsManagerSettings
       ) where

import           Control.Exception
import           Data.ByteString.Lazy                  (ByteString, fromStrict)
import qualified Data.ByteString                       as B
import qualified Data.ByteString                       as B (concat)
import           Data.ByteString.Builder               (toLazyByteString)
import           Data.Either                           (isRight)
import           Data.List                             (find)
import           Data.Proxy
import           Data.Text.Encoding                    (decodeUtf8)
import           Data.Typeable                         (Typeable)
import qualified Network.HTTP.Client                   as HC
import qualified Network.HTTP.Client.MultipartFormData as HC
import qualified Network.HTTP.Client.TLS               as HC (tlsManagerSettings)
import           Network.HTTP.Media                    (RenderHeader (..),
                                                        mapContentMedia)
import           Network.HTTP.Types                    hiding (Query)
import           WebApi.ContentTypes
import           WebApi.Contract
import           WebApi.Internal
import           WebApi.Param
import           WebApi.Util
import           Data.Maybe                            (fromJust)
import           Data.Time.Clock                       (getCurrentTime)

-- | Datatype representing the settings related to client.
data ClientSettings = ClientSettings { baseUrl           :: String     -- ^ base url of the API being called.
                                     , connectionManager :: HC.Manager -- ^ connection manager for the connection.
                                     }

data Route' m r = Route'

-- | Creates the 'Response' type from the response body.
fromClientResponse :: forall m r.( FromHeader (HeaderOut m r)
                              , Decodings (ContentTypes m r) (ApiOut m r)
                              , Decodings (ContentTypes m r) (ApiErr m r)
                              , FromParam 'Cookie (CookieOut m r)

                             ) => HC.Response HC.BodyReader -> IO (Response m r)
fromClientResponse hcResp = do
  let status   = HC.responseStatus hcResp
      hdrsOut  = HC.responseHeaders hcResp
      respBody = HC.responseBody hcResp
      respHdr  = fromHeader hdrsOut :: Validation [ParamErr] (HeaderOut m r)
      respCj   = (HC.destroyCookieJar (HC.responseCookieJar hcResp))
      respCk   = fromCookie (cookieBS respCj)
  -- NOTE: Consuming body strictly
      -- respCk   = fromCookie
  respBodyBSS <- HC.brConsume respBody
  let respBodyBS = fromStrict $ B.concat respBodyBSS
  return $ case Success <$> pure status
               <*> (Validation $ toParamErr $ decode' (Route' :: Route' m r) respBodyBS)
               <*> respHdr
               <*> respCk of
      Validation (Right success) -> success
      Validation (Left _errs) ->
        case ApiError
              <$> pure status
              <*> (Validation $ toParamErr $ decode' (Route' :: Route' m r) respBodyBS)
              <*> (Just <$> respHdr)
              <*> (Just <$> respCk) of
           Validation (Right failure) -> (Failure . Left) failure
           Validation (Left _errs) -> Failure $ Right (OtherError (toException UnknownClientException))
    where toParamErr :: Either String a -> Either [ParamErr] a
          toParamErr (Left _str) = Left []
          toParamErr (Right r)   = Right r

          decode' :: ( Decodings (ContentTypes m r) a
                   ) => apiRes m r -> ByteString -> Either String a
          decode' r o = case getContentType (HC.responseHeaders hcResp) of
            Just ctype -> let decs = decodings (reproxy r) o
                          in maybe (firstRight (map snd decs)) id (mapContentMedia decs ctype)
            Nothing    -> firstRight (map snd (decodings (reproxy r) o))

          reproxy :: apiRes m r -> Proxy (ContentTypes m r)
          reproxy = const Proxy

          firstRight :: [Either String b] -> Either String b
          firstRight = maybe (Left "Couldn't find matching Content-Type") id . find isRight

          cookieBS :: [HC.Cookie] -> [(B.ByteString, B.ByteString)]
          cookieBS = map (\ck -> (HC.cookie_name ck, HC.cookie_value ck))

-- | Creates a request from the 'Request' type.
toClientRequest :: forall m r.( ToParam 'PathParam (PathParam m r)
                          , ToParam 'QueryParam (QueryParam m r)
                          , ToParam 'FormParam (FormParam m r)
                          , ToHeader (HeaderIn m r)
                          , ToParam 'FileParam (FileParam m r)
                          , ToParam 'Cookie (CookieIn m r)
                          , SingMethod m
                          , MkPathFormatString r
                          , PartEncodings (RequestBody m r)
                          , ToHListRecTuple (StripContents (RequestBody m r))
                          ) => HC.Request -> Request m r -> IO HC.Request
toClientRequest clientReq req = do
  now <- getCurrentTime
  let cReq' = clientReq
              { HC.method = singMethod (Proxy :: Proxy m)
              , HC.path = uriPath
              , HC.requestHeaders = toHeader $ headerIn req
              , HC.cookieJar = Just ckJar
              }
      cReqQP = HC.setQueryString queryPar cReq'
      ckJar  = HC.createCookieJar (cks now)
      cReqUE = if Prelude.null formPar
               then cReqQP
               else HC.urlEncodedBody formPar cReqQP
      fileParts = if Prelude.null filePar
                  then []
                  else Prelude.map (\(pname, finfo) -> HC.partFileSource (decodeUtf8 pname) (fileContent finfo)) filePar
      cReqMP = if Prelude.null filePar && Prelude.null formPar
               then case partEncs of
                 (_ : _) -> do
                    let (mt, b) = firstPart
                    return cReqUE { HC.requestHeaders = HC.requestHeaders cReqUE ++ [(hContentType, renderHeader mt)]
                                  , HC.requestBody = HC.RequestBodyLBS $ toLazyByteString b
                                  }
                 [] -> return cReqUE
               else if not (Prelude.null filePar) then HC.formDataBody fileParts cReqUE else return cReqUE
  cReqMP
  where queryPar = toQueryParam $ queryParam req
        formPar = toFormParam $ formParam req
        filePar = toFileParam $ fileParam req
        uriPath = renderUriPath (HC.path clientReq) (pathParam req) req
        firstPart = head . head $ partEncs
        partEncs = partEncodings cts (toRecTuple cts' (requestBody req))
        cts     = Proxy :: Proxy (RequestBody m r)
        cts'     = Proxy :: Proxy (StripContents (RequestBody m r))
        cks now = map (uncurry (mkCookieVal now)) (toCookie $ cookieIn req)
        mkCookieVal now k ci =
          HC.Cookie { HC.cookie_name = k
                    , HC.cookie_value = cookieValue ci
                    , HC.cookie_expiry_time = fromJust (cookieExpires ci)
                    , HC.cookie_domain = fromJust (cookieDomain ci)
                    , HC.cookie_path = fromJust (cookiePath ci)
                    , HC.cookie_creation_time = now
                    , HC.cookie_last_access_time = now
                    , HC.cookie_persistent = False
                    , HC.cookie_host_only = False
                    , HC.cookie_secure_only = fromJust (cookieSecure ci)
                    , HC.cookie_http_only = fromJust (cookieHttpOnly ci)
                    }

-- | Given a `Request` type, create the request and obtain a response. Gives back a 'Response'.
client :: forall m r .
          ( ToParam 'PathParam (PathParam m r)
          , ToParam 'QueryParam (QueryParam m r)
          , ToParam 'FormParam (FormParam m r)
          , ToParam 'Cookie (CookieIn m r)
          , ToHeader (HeaderIn m r)
          , ToParam 'FileParam (FileParam m r)
          , FromHeader (HeaderOut m r)
          , FromParam 'Cookie (CookieOut m r)
          , Decodings (ContentTypes m r) (ApiOut m r)
          , Decodings (ContentTypes m r) (ApiErr m r)
          , SingMethod m
          , MkPathFormatString r
          , PartEncodings (RequestBody m r)
          , ToHListRecTuple (StripContents (RequestBody m r))
          ) => ClientSettings -> Request m r -> IO (Response m r)
client sett req = do
  cReqInit <- HC.parseRequest (baseUrl sett)
  cReq <- toClientRequest cReqInit req
  catches (HC.withResponse cReq (connectionManager sett) fromClientResponse)
    [ Handler (\(ex :: HC.HttpException) -> do
                case ex of
#if MIN_VERSION_http_client(0,5,0)
                  HC.HttpExceptionRequest _req (HC.StatusCodeException resp _) -> do
                    let resHeaders = HC.responseHeaders resp
                        status = HC.responseStatus resp
#else
                  (HC.StatusCodeException status resHeaders _) -> do
#endif
                    let mBody = find ((== "X-Response-Body-Start") . fst) resHeaders
                        bdy   = case mBody of
                                  Nothing -> "[]"
                                  Just (_, body) -> body
                        removeExtraHeaders = filter (\(x, _) -> (x /= "X-Request-URL") || (x /= "X-Response-Body-Start"))
                    return $ case ApiError
                          <$> pure status
                          <*> (Validation $ toParamErr $ decode' resHeaders (Route' :: Route' m r) (fromStrict bdy))
                          <*> (Just <$> (fromHeader . removeExtraHeaders $ resHeaders))
                          -- TODO: Handle cookies
                          <*> pure Nothing of
                       Validation (Right failure) -> (Failure . Left) failure
                       Validation (Left _errs) -> Failure $ Right (OtherError (toException UnknownClientException))
                  _ -> return . Failure . Right . OtherError $ toException ex
                      )
    , Handler (\(ex :: IOException) -> return . Failure . Right . OtherError $ toException ex)
    ]
    where toParamErr :: Either String a -> Either [ParamErr] a
          toParamErr (Left _str) = Left []
          toParamErr (Right r)   = Right r

          decode' :: ( Decodings (ContentTypes m r) a
                   ) => [Header] -> apiRes m r -> ByteString -> Either String a
          decode' h r o = case getContentType h of
            Just ctype -> let decs = decodings (reproxy r) o
                          in maybe (firstRight (map snd decs)) id (mapContentMedia decs ctype)
            Nothing    -> firstRight (map snd (decodings (reproxy r) o))

          reproxy :: apiRes m r -> Proxy (ContentTypes m r)
          reproxy = const Proxy

          firstRight :: [Either String b] -> Either String b
          firstRight = maybe (Left "Couldn't find matching Content-Type") id . find isRight

-- | This exception is used to signal an irrecoverable error while deserializing the response.
data UnknownClientException = UnknownClientException
                            deriving (Typeable, Show)

instance Exception UnknownClientException where
