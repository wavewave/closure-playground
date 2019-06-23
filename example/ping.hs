{-# LANGUAGE BangPatterns          #-}
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
import Control.Concurrent.Async (withAsync)
import Control.Concurrent.Chan (Chan,newChan,readChan,writeChan)
import Control.Distributed.Closure (Closure,cpure,closureDict,unclosure)
import Control.Distributed.Closure.TH (withStatic)
import Control.Monad (forever) --  replicateM_
import Data.Binary (Binary,decode,decodeOrFail,encode)
import qualified Data.ByteString.Lazy as BL
import Data.Functor.Static (staticMap)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import GHC.StaticPtr (StaticKey,deRefStaticPtr,staticKey,unsafeLookupStaticPtr)
import Network.Simple.TCP ( HostPreference(Host)
                          , connect
                          , serve
                          )
import System.Environment (getArgs)
-- import System.Random (randomIO)
--
import Comm (RPort(..),SPort(..),receiveChan,sendChan)


-- | An instruction to the server.
data Instruction
  = CallStatic StaticKey Int
    -- ^ @CallStatic skFun arg@
    --
    -- Apply the function behind the 'StaticKey' @skFun@ to @arg@.
  | CallClosure (Closure (Int -> Int)) Int
    -- ^ @CallClosure cl arg@
    --
    -- Apply the closure @cl@ to @arg@.
  deriving Generic
instance Binary Instruction

-- | Handle an instruction by the client.
--
-- This is where we resolve a 'StaticKey'
-- by looking up the 'StaticPtr' and dereferencing it.
--
-- This is also where we resolve a 'Closure'.
handleInstruction :: Instruction -> IO (Maybe Int)
handleInstruction (CallStatic skey input) = do
  mbSPtr <- unsafeLookupStaticPtr skey
  return $ case mbSPtr of
    Nothing -> Nothing
    Just sptr ->
      let fun = deRefStaticPtr sptr in
      Just $ fun input
handleInstruction (CallClosure cl input) =
  let fun = unclosure cl in
  return $ Just $ fun input


-- | A global function that can be packed into a 'CallStatic' instruction.
double :: Int -> Int
double = (*2)

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
    let rport = RPort sock
    forever $ do
      req <- receiveChan rport
      mr <- handleInstruction req
      print mr

master :: IO ()
master = do
  connect "127.0.0.1" "3929" $ \(sock, remoteAddr) -> do
    putStrLn $ "Connection established to " ++ show remoteAddr
    threadDelay 2500000
    let sport = SPort sock
    ------
    let fun = staticKey $ static double
        req1 = CallStatic fun 4
    sendChan sport req1
    ------
    let three = SI 3
        c = static (\(SI a) b -> a + b)
          `staticMap` cpure closureDict three
        req2 = CallClosure c 4
    sendChan sport req2


main :: IO ()
main = do
  a0:_ <- getArgs
  case a0 of
    "slave"  -> slave
    "master" -> master
