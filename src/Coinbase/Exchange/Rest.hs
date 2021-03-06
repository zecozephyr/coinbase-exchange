{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}

module Coinbase.Exchange.Rest
    ( coinbaseGet
    , coinbasePost
    , coinbaseDelete
    , coinbaseDeleteDiscardBody
    , voidBody
    ) where

import           Control.Monad.Except
import           Control.Monad.Reader
import           Control.Monad.Trans.Resource
import           Crypto.Hash
import           Data.Aeson
import           Data.Byteable
import qualified Data.ByteString              as BS
import qualified Data.ByteString.Base64       as Base64
import qualified Data.ByteString.Char8        as CBS
import qualified Data.ByteString.Lazy         as LBS
import           Data.Conduit
import           Data.Conduit.Attoparsec      (sinkParser)
import qualified Data.Conduit.Binary          as CB
import qualified Data.Text                    as T
import qualified Data.Text.Encoding           as T
import           Data.Time
import           Data.Time.Clock.POSIX
import           Network.HTTP.Conduit
import           Network.HTTP.Types
import           Text.Printf

import           Coinbase.Exchange.Types

import Debug.Trace

type Signed = Bool

voidBody :: Maybe ()
voidBody = Nothing

coinbaseGet :: ( ToJSON a
               , FromJSON b
               , MonadResource m
               , MonadReader ExchangeConf m
               , MonadError ExchangeFailure m )
            => Signed -> Path -> Maybe a -> m b
coinbaseGet sgn p ma = coinbaseRequest "GET" sgn p ma >>= processResponse

coinbasePost :: ( ToJSON a
                , FromJSON b
                , MonadResource m
                , MonadReader ExchangeConf m
                , MonadError ExchangeFailure m )
             => Signed -> Path -> Maybe a -> m b
coinbasePost sgn p ma = coinbaseRequest "POST" sgn p ma >>= processResponse

coinbaseDelete :: ( ToJSON a
                  , FromJSON b
                  , MonadResource m
                  , MonadReader ExchangeConf m
                  , MonadError ExchangeFailure m )
               => Signed -> Path -> Maybe a -> m b
coinbaseDelete sgn p ma = coinbaseRequest "DELETE" sgn p ma >>= processResponse

coinbaseDeleteDiscardBody :: ( ToJSON a
                             , MonadResource m
                             , MonadReader ExchangeConf m
                             , MonadError ExchangeFailure m )
                             => Signed -> Path -> Maybe a -> m ()
coinbaseDeleteDiscardBody sgn p ma = coinbaseRequest "DELETE" sgn p ma >>= processEmpty

coinbaseRequest :: ( ToJSON a
                   , MonadResource m
                   , MonadReader ExchangeConf m
                   , MonadError ExchangeFailure m )
                => Method -> Signed -> Path -> Maybe a -> m (Response (ResumableSource m BS.ByteString))
coinbaseRequest meth sgn p ma = do
        conf <- ask
        req  <- case apiType conf of
                    Sandbox -> parseUrl $ sandboxRest ++ p
                    Live    -> parseUrl $ liveRest ++ p
        let req' = req { method         = meth
                       , requestHeaders = [ ("user-agent", "haskell")
                                          , ("accept", "application/json")
                                          ]
                       }

        flip http (manager conf) =<< signMessage sgn meth p
                                 =<< encodeBody ma req'

encodeBody :: (ToJSON a, Monad m)
           => Maybe a -> Request -> m Request
encodeBody (Just a) req = return req
                            { requestHeaders = requestHeaders req ++
                                               [ ("content-type", "application/json") ]
                            , requestBody = RequestBodyBS $ LBS.toStrict $ encode a
                            }
encodeBody Nothing  req = return req

signMessage :: (MonadIO m, MonadReader ExchangeConf m, MonadError ExchangeFailure m)
            => Signed -> Method -> Path -> Request -> m Request
signMessage True meth p req = do
        conf <- ask
        case authToken conf of
            Just tok -> do time <- liftM (realToFrac . utcTimeToPOSIXSeconds) (liftIO getCurrentTime)
                                    >>= \t -> return . CBS.pack $ printf "%.0f" (t::Double)
                           rBody <- pullBody $ requestBody req
                           let presign = CBS.concat [time, meth, CBS.pack p, rBody]
                               sign    = toBytes (hmac (secret tok) presign :: HMAC SHA256)
                           return req
                                { requestBody    = RequestBodyBS rBody
                                , requestHeaders = requestHeaders req ++
                                       [ ("cb-access-key", key tok)
                                       , ("cb-access-sign", Base64.encode sign)
                                       , ("cb-access-timestamp", time)
                                       , ("cb-access-passphrase", passphrase tok)
                                       ]
                                }
            Nothing  -> throwError $ AuthenticationRequiredFailure $ T.pack p
    where pullBody (RequestBodyBS  b) = return b
          pullBody (RequestBodyLBS b) = return $ LBS.toStrict b
          pullBody _                  = throwError AuthenticationRequiresByteStrings
signMessage False _ _ req = return req

--

processResponse :: ( FromJSON b
                   , MonadResource m
                   , MonadReader ExchangeConf m
                   , MonadError ExchangeFailure m )
                => Response (ResumableSource m BS.ByteString) -> m b
processResponse res =
    case responseStatus res of
--  this is why monadically chaining Exchange actions is useless. before proceeding we invariably finalize the resumable resource
--  if instead the resumable resource was returned, so we could operate on the data as needed, that could be beneficial
        s | s == status200 -> do body <- responseBody res $$+- sinkParser (fmap {-(\x -> trace (show x) fromJSON x)-} fromJSON json)
--        s | s == status200 -> do body <- responseBody res $$+- sinkParser (fmap (\x -> trace (show x) fromJSON x) json)
                                 case body of
                                     Success b -> return b
                                     Error  er -> throwError $ ParseFailure $ T.pack er
          | otherwise      -> do body <- responseBody res $$+- CB.sinkLbs
                                 throwError $ ApiFailure $ T.decodeUtf8 $ LBS.toStrict body

processEmpty :: ( MonadResource m
                , MonadReader ExchangeConf m
                , MonadError ExchangeFailure m )
             => Response (ResumableSource m BS.ByteString) -> m ()
processEmpty res =
    case responseStatus res of
        s | s == status200 -> return ()
          | otherwise      -> do body <- responseBody res $$+- CB.sinkLbs
                                 throwError $ ApiFailure $ T.decodeUtf8 $ LBS.toStrict body
