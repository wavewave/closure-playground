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
{-# LANGUAGE TypeApplications      #-}

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
import Data.Binary (Binary(get,put))
import Data.Dynamic.Binary (Dynamic,dynTypeRep,toDyn)
import Data.Functor.Static (staticMap)
import qualified Data.Map.Strict as M
-- import Data.Proxy (Proxy(..))
import qualified Data.Text as T
import Data.Typeable (Typeable,TypeRep,TyCon)
-- import Data.Typeable.Internal ()
import GHC.Generics (Generic)
import Network.Simple.TCP ( HostPreference(Host)
                          , connect
                          , serve
                          )
import System.Environment (getArgs)
import System.Random (randomIO)
import Type.Reflection ()
--
import Comm ( BinProxy(..)
            , ChanState(..)
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


-- | Request type
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
      (_,rp_typ) <- newChan -- fixed id = 0
      (_,rp_req) <- newChan -- fixed id = 1
      forever $ do
        dyn :: Dynamic <- receiveChan rp_typ
        liftIO $ print (dynTypeRep dyn)
        req@(Request _ _ sp_ans :: Request Int Int) <- receiveChan rp_req
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
      let sp_typ = SPort 0 -- type
          sp_req = SPort 1 -- request

      replicateM_ 5 $ do
        (sp_ans,rp_ans) <- newChan @Int
        h <- lift $ randomIO
        let hidden = SI h
            c = static (\(SI a) b -> a + b)
              `staticMap` cpure closureDict hidden
            req = Request c (4::Int) sp_ans

        logText $ "sending type information"
        sendChan sp_typ (toDyn (BinProxy @Int))

        logText $ "sending req with hidden: " <> T.pack (show h)
        sendChan sp_req req
        ans <- receiveChan rp_ans
        logText $ "get answer = " <> T.pack (show ans)
        lift $ threadDelay 1200000

main :: IO ()
main = do
  a0:_ <- getArgs
  case a0 of
    "slave"  -> slave
    "master" -> master
