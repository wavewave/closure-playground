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
import Control.Monad.Loops (whileJust_)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Reader (ask)
import Data.Binary (Binary(get,put))
import Data.Binary.Get (Get(..))
import Data.Binary.Put (Put(..))
import Data.Dynamic (fromDynamic,toDyn)
import Data.Foldable (for_)
import Data.Functor.Static (staticMap)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Data.Typeable (Typeable,TypeRep,TyCon)
import GHC.Generics (Generic)
import GHC.StaticPtr (StaticPtr(..),deRefStaticPtr,staticKey,unsafeLookupStaticPtr)
import Network.Simple.TCP ( HostPreference(Host)
                          , connect
                          , serve
                          )
import System.Environment (getArgs)
import System.IO.Unsafe (unsafePerformIO)
import System.Random (randomIO)
import Type.Reflection (typeRep,withTypeable)
--
import Comm ( BinProxy(..)
            , ChanState(..)
            , IMsg(..)
            , Msg(..)
            , Managed
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


-- | Request type
data Request a b = Request (Closure (a -> b)) (SPort (SPort (Maybe a))) (SPort b)
                   deriving (Generic, Typeable)

instance (Serializable a, Serializable b) => Binary (Request a b)


-- ref: https://github.com/haskell-distributed/cloud-haskell/issues/7
--      http://neilmitchell.blogspot.com/2017/09/existential-serialisation.html
-- | existential request type
data SomeRequest = forall a b. (Serializable a, Serializable b, StaticSomeRequest (Request a b), Show a, Show b) => SomeRequest (Request a b)

class StaticSomeRequest a where
  staticSomeRequest :: a -> StaticPtr (Get SomeRequest)

instance StaticSomeRequest (Request Int Int) where
  staticSomeRequest _ = static (SomeRequest <$> (get :: Get (Request Int Int)))

instance StaticSomeRequest (Request Int String) where
  staticSomeRequest _ = static (SomeRequest <$> (get :: Get (Request Int String)))

instance Binary SomeRequest where
  put :: SomeRequest -> Put
  put (SomeRequest req) = do
    put $ staticKey (staticSomeRequest req)
    put req

  get :: Get SomeRequest
  get = do
    k <- get
    case unsafePerformIO (unsafeLookupStaticPtr k) of
      Just ptr -> deRefStaticPtr ptr :: Get SomeRequest
      Nothing -> error "Binary SomeRequest: unknown static pointer"


-- | Handle an instruction by the client.
--
handleRequest ::
     (Serializable b)
  => Request a b
  -> a
  -> IO b
handleRequest (Request cl _ _) input =
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

      replicateM_ 3 $ task1 sp_req
      replicateM_ 3 $ task2 sp_req

task1 :: SPort SomeRequest -> Managed ()
task1 sp_req = do
  (sp_ans,rp_ans) <- newChan @Int
  (sp_sp,rp_sp) <- newChan @(SPort (Maybe Int))
  h <- lift $ randomIO
  let hidden = SI h
      c = static (\(SI a) b -> a + b)
        `staticMap` cpure closureDict hidden
      req = Request c sp_sp sp_ans

  logText $ "sending req with hidden: " <> T.pack (show h)
  sendChan sp_req (SomeRequest req)

  logText $ "receiving sp_input"
  sp_input <- receiveChan rp_sp

  for_ [4,5,6,7,8] $ \input -> do
    sendChan sp_input (Just input)
    ans <- receiveChan rp_ans
    logText $ "get answer = " <> T.pack (show ans)
    lift $ threadDelay 1200000
  sendChan sp_input Nothing


task2 :: SPort SomeRequest -> Managed ()
task2 sp_req = do
  (sp_ans,rp_ans) <- newChan @String
  (sp_sp,rp_sp) <- newChan @(SPort (Maybe Int))
  h <- lift $ randomIO
  let hidden = SI h
      c = static (\(SI a) b -> show a ++ ":" ++ show b)
        `staticMap` cpure closureDict hidden
      req = Request c sp_sp sp_ans

  logText $ "sending req with hidden: " <> T.pack (show h)
  sendChan sp_req (SomeRequest req)

  logText $ "receiving sp_input"
  sp_input <- receiveChan rp_sp

  for_ [100,200,300] $ \input -> do
    sendChan sp_input (Just input)
    ans <- receiveChan rp_ans
    logText $ "get answer = " <> T.pack (show ans)
    lift $ threadDelay 1200000
  sendChan sp_input Nothing


main :: IO ()
main = do
  a0:_ <- getArgs
  case a0 of
    "slave"  -> slave
    "master" -> master
