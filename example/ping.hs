{-# LANGUAGE BangPatterns              #-}
{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE InstanceSigs              #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE StaticPointers            #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE TypeApplications          #-}

{-# OPTIONS_GHC -Wall -Werror -fno-warn-incomplete-patterns -fno-warn-orphans #-}
module Main where

import Control.Concurrent (threadDelay)
import Control.Distributed.Closure (Closure, cpure, closureDict)
import Control.Distributed.Closure.TH (withStatic)
import Control.Monad (forever, replicateM)
import Control.Monad.Loops (whileJust_)
import Control.Monad.Trans.Class (lift)
import Data.Binary (Binary(get))
import Data.Binary.Get (Get)
import Data.Functor.Static (staticMap)
import qualified Data.Text as T
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Network.Simple.TCP ( HostPreference(Host)
                          , connect
                          , serve
                          )
import System.Environment (getArgs)
import System.Random (randomIO)
--
import Comm ( Managed
            , SPort(..)
            , receiveChan
            , sendChan
            , newChan
            , runManaged
            , logText
            )
import Request ( Request(..)
               , SomeRequest(..)
               , StaticSomeRequest(..)
               , callRequest
               , handleRequest
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


slave :: IO ()
slave = do
  serve (Host "127.0.0.1") "3929" $ \(sock, remoteAddr) -> do
    putStrLn $ "TCP connection established from " ++ show remoteAddr
    runManaged sock $ do
      (_,rp_req) <- newChan -- fixed id = 0
      forever $ do
        SomeRequest req <- receiveChan rp_req
        let Request _ sp_sp sp_ans = req
        (sp_input,rp_input) <- newChan
        logText $ "sp_input sent:"
        sendChan sp_sp sp_input
        whileJust_ (receiveChan rp_input) $ \input -> do
          logText $ "requested for input: " <> T.pack (show input)
          ans <- lift $ handleRequest req input
          logText $ "request handled with answer: " <> T.pack (show ans)
          sendChan sp_ans ans
          logText $ "answer sent"


master :: IO ()
master = do
  connect "127.0.0.1" "3929" $ \(sock, remoteAddr) -> do
    putStrLn $ "Connection established to " ++ show remoteAddr
    threadDelay 2500000
    runManaged sock $ do
      let sp_req = SPort 0

      rs1 <- replicateM 3 $ (mkclosure1 >>= \clsr -> callRequest sp_req clsr [1,2,3])
      logText $ T.pack (show rs1)
      rs2 <- replicateM 3 $ (mkclosure2 >>= \clsr -> callRequest sp_req clsr [100,200,300::Int])
      logText $ T.pack (show rs2)


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

main :: IO ()
main = do
  a0:_ <- getArgs
  case a0 of
    "slave"  -> slave
    "master" -> master
