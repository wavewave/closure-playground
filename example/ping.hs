{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE StaticPointers        #-}
{-# LANGUAGE TemplateHaskell       #-}

-- {-# OPTIONS_GHC -Wall -Werror -fno-warn-incomplete-patterns #-}
module Main where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, readTVar, writeTVar, newTChan, readTChan)
import Control.Distributed.Closure ( Closure
                                   , Serializable
                                   , cpure
                                   , closureDict
                                   , unclosure
                                   )
import Control.Distributed.Closure.TH (withStatic)
import Control.Monad (forever, replicateM_)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Reader (ask)
import Data.Binary (Binary)
import Data.Functor.Static (staticMap)
import qualified Data.Map.Strict as M
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
import Comm ( ChanState(..)
            , IMsg(..)
            , Msg(..)
            , RPort(..)
            , SPort(..)
            , receiveChan
            , sendChan
            , newChan
            , sendIMsg
            , sendMsg
            , runManaged
            , logText
            )


data Request a b = Request (Closure (a -> b)) a
                   deriving (Generic, Typeable)

instance (Serializable a, Serializable b) => Binary (Request a b)

-- | Handle an instruction by the client.
--
handleRequest ::
     (Serializable b, Show b)
  => Request a b
  -> IO b
handleRequest (Request cl input) =
  let fun = unclosure cl
  in pure $ fun input


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
      (_,rp) <- newChan
      forever $ do
        x :: Int <- receiveChan rp
        logText ("data dispatched: " <> T.pack (show x))
        {-
        let rport_req = RPort sock
            sport_ans = SPort sock
        req :: Request Int Int <- receiveChan rport_req
        r <- lift $ handleRequest req
        lift $ putStrLn $ "request handled with answer: " ++ show r
        sendChan sport_ans r
        -}

master :: IO ()
master = do
  connect "127.0.0.1" "3929" $ \(sock, remoteAddr) -> do
    putStrLn $ "Connection established to " ++ show remoteAddr
    threadDelay 2500000
    runManaged sock $ do

      replicateM_ 5 $ do
        liftIO $ threadDelay 1200000
        let sport = SPort 0
        sendChan sport (12345 :: Int)

      {-
      let sport_req = SPort sock
          rport_ans = RPort sock
      ------
      replicateM_ 3 $ do
        h <- lift $ randomIO
        lift $ putStrLn $ "h = " ++ show h
        let hidden = SI h
            c = static (\(SI a) b -> a + b)
              `staticMap` cpure closureDict hidden
            req = (c,4::Int)
        lift $ putStrLn "sending req"
        sendChan sport_req req
        mans :: Maybe Int <- receiveChan rport_ans
        lift $ putStrLn $ "get ans = " ++ show mans
      -}

main :: IO ()
main = do
  a0:_ <- getArgs
  case a0 of
    "slave"  -> slave
    "master" -> master
