{-# LANGUAGE ExplicitNamespaces        #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE TupleSections             #-}
{-# OPTIONS_GHC -Wall -Werror #-}
module MasterSlave where

import Control.Monad (forever)
import Control.Monad.Loops (whileJust_)
import Control.Monad.Trans.Class (lift)
import Data.Foldable (traverse_)
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T
import Data.Traversable (traverse)
import Network.Simple.TCP ( HostPreference(Host)
                          , type HostName
                          , type ServiceName
                          , connectSock
                          , closeSock
                          , serve
                          )
--
import Comm ( Managed
            , NodeName(..)
            , SocketPool(..)
            , receiveChan
            , sendChan
            , newChan
            , runManaged
            , logText
            )
import Request ( Request(..)
               , SomeRequest(..)
               , handleRequest
               )


slave :: NodeName -> HostName -> ServiceName -> IO ()
slave node hostName serviceName = do
  serve (Host hostName) serviceName $ \(sock, remoteAddr) -> do
    putStrLn $ "TCP connection established from " ++ show remoteAddr
    let pool = SocketPool $ HM.fromList [(NodeName "master",(sock,remoteAddr))]
    runManaged node pool $ do
      (_,rp_req) <- newChan -- fixed id = 0
      forever $ do
        SomeRequest req <- receiveChan rp_req
        let (sp_sp,sp_ans) = case req of
                               PureRequest _ sp_sp' sp_ans' -> (sp_sp',sp_ans')
                               IORequest   _ sp_sp' sp_ans' -> (sp_sp',sp_ans')
        (sp_input,rp_input) <- newChan
        logText $ "sp_input sent:"
        sendChan sp_sp sp_input
        whileJust_ (receiveChan rp_input) $ \input -> do
          logText $ "requested for input: " <> T.pack (show input)
          ans <- lift $ handleRequest req input
          logText $ "request handled with answer: " <> T.pack (show ans)
          sendChan sp_ans ans
          logText $ "answer sent"

master :: [(NodeName,(HostName,ServiceName))] -> Managed a -> IO a
master slaveList task = do
  pool <-
    SocketPool . HM.fromList <$>
      traverse (\(n,(h,s)) -> fmap (n,) (connectSock h s)) slaveList

  -- threadDelay 2500000
  r <- runManaged (NodeName "master") pool task
  traverse_ (closeSock . fst) $ sockPoolMap pool
  pure r
