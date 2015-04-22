{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE UndecidableInstances       #-}

module Coinbase.Exchange.Types where

import           Control.Applicative
import           Control.Monad.Base
import           Control.Monad.Except
import           Control.Monad.Reader
import           Control.Monad.Trans.Resource

data ExchangeConf = ExchangeConf

data ExchangeFailure = ExchangeFailure

type Exchange a = ExchangeT IO a

newtype ExchangeT m a = ExchangeT { unExchangeT :: ResourceT (ReaderT ExchangeConf (ExceptT ExchangeFailure m)) a }
    deriving ( Functor, Applicative, Monad, MonadIO, MonadThrow
             , MonadError ExchangeFailure
             , MonadReader ExchangeConf
             )

deriving instance (MonadBase IO m) => MonadBase IO (ExchangeT m)
deriving instance (Monad m, MonadThrow m, MonadIO m, MonadBase IO m) => MonadResource (ExchangeT m)

runExchange :: ExchangeConf -> Exchange a -> IO (Either ExchangeFailure a)
runExchange = runExchangeT

runExchangeT :: MonadBaseControl IO m => ExchangeConf -> ExchangeT m a -> m (Either ExchangeFailure a)
runExchangeT conf = runExceptT . flip runReaderT conf . runResourceT . unExchangeT