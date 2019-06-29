{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE ExplicitNamespaces        #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE StaticPointers            #-}
{-# LANGUAGE TemplateHaskell           #-}

{-# OPTIONS_GHC -Wall -Werror -fno-warn-incomplete-patterns -fno-warn-orphans #-}
module Main where

import Control.Concurrent (threadDelay)
import Control.Distributed.Closure (Closure, cpure, closureDict)
import Control.Distributed.Closure.TH (withStatic)
import Control.Monad (replicateM)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Class (lift)
import Data.Binary (Binary(get))
import Data.Binary.Get (Get)
import Data.Functor.Static (staticMap)
import qualified Data.List as L
import qualified Data.Text as T
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Network.Simple.TCP (type HostName, type ServiceName)
import System.Environment (getArgs)
import System.Random (randomIO)
import UnliftIO.Async (async,wait)
--
import Comm ( Managed
            , NodeName(..)
            , logText
            )
import MasterSlave (master,slave)
import Request ( Request(..)
               , SomeRequest(..)
               , StaticSomeRequest(..)
               , requestTo
               )


instance StaticSomeRequest (Request Int Int) where
  staticSomeRequest _ = static (SomeRequest <$> (get :: Get (Request Int Int)))

instance StaticSomeRequest (Request Int String) where
  staticSomeRequest _ = static (SomeRequest <$> (get :: Get (Request Int String)))


-- | A wrapper around 'Int' used to fulfill the 'Serializable' constraint,
-- so that it can be packed into a 'Closure'.
newtype SerializableInt = SI Int deriving (Generic, Typeable)
withStatic [d|
  instance Binary SerializableInt
  instance Typeable SerializableInt
  |]

mkclosure1 :: Managed (Closure (Int -> Int))
mkclosure1 = do
  h <- lift $ randomIO
  let hidden = SI h
      c = static (\(SI a) b -> a + b)
        `staticMap` cpure closureDict hidden
  logText $ "sending req with hidden: " <> T.pack (show h)
  pure c

mkclosure2 :: Managed (Closure (Int -> String))
mkclosure2 = do
  h <- lift $ randomIO
  let hidden = SI h
      c = static (\(SI a) b -> show a ++ ":" ++ show b)
        `staticMap` cpure closureDict hidden
  logText $ "sending req with hidden: " <> T.pack (show h)
  pure c

nodeList :: [(NodeName,(HostName,ServiceName))]
nodeList = [ (NodeName "slave1", ("127.0.0.1", "3929"))
           , (NodeName "slave2", ("127.0.0.1", "3939"))
           ]

process :: IO ()
process = do
  master nodeList$ do
    a1 <-async $
             replicateM 3 $ do
               liftIO (threadDelay 1000000)
               mkclosure1 >>= \clsr -> requestTo (NodeName "slave1") clsr [1,2,3]
    a2 <-async $
             replicateM 3 $ do
               liftIO (threadDelay 1000000)
               mkclosure2 >>= \clsr -> requestTo (NodeName "slave2") clsr [100,200,300::Int]
    rs1 <- wait a1
    rs2 <- wait a2
    logText $ T.pack (show rs1)
    logText $ T.pack (show rs2)

main :: IO ()
main = do
  a0:_ <- getArgs
  case a0 of
    "master" -> process
    _ -> let name = NodeName (T.pack a0)
         in case L.lookup name nodeList of
              Just (hostName,serviceName) -> slave name hostName serviceName
              Nothing -> error $ "cannot find " ++ a0
