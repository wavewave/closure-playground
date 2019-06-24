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
import Data.Binary (Binary)
import Data.Functor.Static (staticMap)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Network.Simple.TCP ( HostPreference(Host)
                          , connect
                          , serve
                          )
import System.Environment (getArgs)
import System.Random (randomIO)
--
import Comm (IMsg(..),Msg(..),RPort(..),SPort(..),receiveChan,sendChan,sendIMsg,sendMsg,runManaged)


data Request a b = Request (Closure (a -> b)) a
                   deriving (Generic, Typeable)

instance (Serializable a, Serializable b) => Binary (Request a b)

-- | Handle an instruction by the client.
--
handleRequest ::
     (Serializable b, Show b)
  => Request a b
  -> IO (Maybe b)
handleRequest (Request cl input) =
  let fun = unclosure cl in
  return $ Just $ fun input


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
      forever $ liftIO $ do
        threadDelay 1500000
        putStrLn "tick"
        {-
        let rport_req = RPort sock
            sport_ans = SPort sock
        req :: Request Int Int <- receiveChan rport_req
        mr <- lift $ handleRequest req
        lift $ putStrLn $ "request handled with answer: " ++ show mr
        sendChan sport_ans mr
        -}

master :: IO ()
master = do
  connect "127.0.0.1" "3929" $ \(sock, remoteAddr) -> do
    putStrLn $ "Connection established to " ++ show remoteAddr
    threadDelay 2500000
    runManaged sock $ do
      replicateM_ 5 $ liftIO $ do
        threadDelay 1200000
        sendIMsg sock (IMsg 1928 4 "abcd")

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
