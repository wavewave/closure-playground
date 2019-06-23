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

{-# OPTIONS_GHC -Wall -Werror -fno-warn-incomplete-patterns #-}
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
import Comm (RPort(..),SPort(..),receiveChan,sendChan)

{-
-- | An instruction to the server.
data Instruction
  = CallClosure (Closure (Int -> Int)) Int
    -- ^ @CallClosure cl arg@
    --
    -- Apply the closure @cl@ to @arg@.
  deriving Generic
instance Binary Instruction
-}

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
    forever $ do
    let rport_req = RPort sock
        sport_ans = SPort sock
    forever $ do
      req :: Request Int Int <- receiveChan rport_req
      mr <- handleRequest req
      putStrLn $ "request handled with answer: " ++ show mr
      sendChan sport_ans mr


master :: IO ()
master = do
  connect "127.0.0.1" "3929" $ \(sock, remoteAddr) -> do
    putStrLn $ "Connection established to " ++ show remoteAddr
    threadDelay 2500000
    let sport_req = SPort sock
        rport_ans = RPort sock
    ------
    replicateM_ 3 $ do
      h <- randomIO
      putStrLn $ "h = " ++ show h
      let hidden = SI h
          c = static (\(SI a) b -> a + b)
            `staticMap` cpure closureDict hidden
          req = (c,4::Int)
      putStrLn "sending req"
      sendChan sport_req req
      mans :: Maybe Int <- receiveChan rport_ans
      putStrLn $ "get ans = " ++ show mans


main :: IO ()
main = do
  a0:_ <- getArgs
  case a0 of
    "slave"  -> slave
    "master" -> master
