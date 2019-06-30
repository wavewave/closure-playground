{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE ExplicitNamespaces        #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE StaticPointers            #-}
{-# LANGUAGE TemplateHaskell           #-}

-- {-# OPTIONS_GHC -Wall -Werror -fno-warn-incomplete-patterns -fno-warn-orphans #-}
module Main where

import Control.Concurrent (threadDelay)
import Control.Distributed.Closure (Closure, cap, cpure, closure, closureDict)
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
import System.Random (randomIO,randomRIO)
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
               , requestToM
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

-- test for sending arbitrary IO action
mkclosure3 :: Managed (Closure (Int -> Managed String))
mkclosure3 = do
  h <- lift $ randomIO
  let hidden = SI h
      c = static (\(SI a) b -> do let x = show a ++ ":" ++ show b
                                  logText ("nuclear missile launched with " <> T.pack (show x))
                                  pure x
                 )
        `staticMap` cpure closureDict hidden
  logText $ "sending req with hidden: " <> T.pack (show h)
  pure c


-- higher order function
mkclosure4 :: Managed (Closure (Int -> Managed String))
mkclosure4 = do
  let func x = x + 10
  let -- hidden = SI h
      c1 = closure $ static \(f :: Int->Int) (b :: Int) -> do
                               let x = show (f 1) ++ ":" ++ show b
                               logText ("nuclear missile launched with " <> T.pack (show x))
                               pure (x :: String)
      c = c1 `cap` closure (static func)
  pure c

-- test for sending arbitrary IO action
mkclosure5 :: Managed (Closure (Int -> Managed String))
mkclosure5 = do
  h <- lift $ randomRIO (0,10)
  logText $ "h = " <> T.pack (show h)
  let c1 = closure $ static \(f :: Int->Int) (b :: Int) -> do
                               let x = show (f 1) ++ ":" ++ show b
                               logText ("nuclear missile launched with " <> T.pack (show x))
                               pure (x :: String)
      f1 = closure (static (\(SI h') x -> x + h')) `cap` cpure closureDict (SI h)
      clsr = c1 `cap` f1
  pure clsr


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
    a3 <-async $
             replicateM 3 $ do
               liftIO (threadDelay 1000000)
               mkclosure3 >>= \clsr -> requestToM (NodeName "slave2") clsr [100,200,300::Int]

    a4 <-async $
             replicateM 3 $ do
               liftIO (threadDelay 1000000)
               mkclosure4 >>= \clsr -> requestToM (NodeName "slave1") clsr [100,200,300::Int]
    a5 <-async $
             replicateM 3 $ do
               liftIO (threadDelay 1000000)
               mkclosure5 >>= \clsr -> requestToM (NodeName "slave2") clsr [100,200,300::Int]


    rs1 <- wait a1
    rs2 <- wait a2
    rs3 <- wait a3
    rs4 <- wait a4
    rs5 <- wait a5

    logText $ T.pack (show rs1)
    logText $ T.pack (show rs2)
    logText $ T.pack (show rs3)
    logText $ T.pack (show rs4)
    logText $ T.pack (show rs5)


main :: IO ()
main = do
  a0:_ <- getArgs
  case a0 of
    "master" -> process
    _ -> let name = NodeName (T.pack a0)
         in case L.lookup name nodeList of
              Just (hostName,serviceName) -> slave name hostName serviceName
              Nothing -> error $ "cannot find " ++ a0
