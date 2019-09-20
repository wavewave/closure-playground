{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE StaticPointers        #-}
{-# LANGUAGE TypeApplications      #-}

module Main where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, readTVar, writeTVar, newTChan, readTChan)
import Control.Distributed.Closure ( Closure
                                   , Dict (..)
                                   , Serializable
                                   , Static(..)
                                   , cap
                                   , cpure
                                   , closure
                                   , closureDict
                                   , unclosure
                                   )
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
import GHC.StaticPtr (StaticPtr)
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


data Request a b = Request (Closure (a -> b)) a (SPort b)
                   deriving (Generic, Typeable)

instance (Serializable a, Serializable b) => Binary (Request a b)

-- | Handle an instruction by the client.
--
handleRequest ::
     (Serializable b, Show b)
  => Request a b
  -> IO b
handleRequest (Request cl input _) =
  let fun = unclosure cl
  in pure $ fun input

instance Static (Binary Int) where
  closureDict = closure (static f :: StaticPtr (Dict (Binary Int)))
    where
      f :: Dict (Binary Int)
      f = Dict

instance Static (Typeable Int) where
  closureDict = closure (static f :: StaticPtr (Dict (Typeable Int)))
    where
      f :: Dict (Typeable Int)
      f = Dict

{-

-- if we use template haskell utility

withStatic [d|
  instance Binary Int
  instance Typeable Int
  |]
-}


slave :: IO ()
slave = do
  serve (Host "127.0.0.1") "3929" $ \(sock, remoteAddr) -> do
    putStrLn $ "TCP connection established from " ++ show remoteAddr
    runManaged sock $ do
      (_,rp) <- newChan -- fixed id = 0
      forever $ do
        req@(Request _ _ sp_ans :: Request Int Int) <- receiveChan rp
        logText $ "requested:"
        ans <- lift $ handleRequest req
        logText $ "request handled with answer: " <> T.pack (show ans)
        sendChan sp_ans ans
        logText $ "answer sent"

master :: IO ()
master = do
  connect "127.0.0.1" "3929" $ \(sock, remoteAddr) -> do
    putStrLn $ "Connection established to " ++ show remoteAddr
    threadDelay 2500000
    runManaged sock $ do

      replicateM_ 5 $ do
        (sp_ans,rp_ans) <- newChan @Int
        hidden :: Int <- lift $ randomIO
        let c = closure (static (\a b -> a + b))
                `cap`
                cpure closureDict hidden
            req = Request c (4::Int) sp_ans

        let sp = SPort 0
        logText $ "sending req with hidden: " <> T.pack (show hidden)
        sendChan sp req
        ans <- receiveChan rp_ans
        logText $ "get answer = " <> T.pack (show ans)
        lift $ threadDelay 1200000

main :: IO ()
main = do
  a0:_ <- getArgs
  case a0 of
    "slave"  -> slave
    "master" -> master
