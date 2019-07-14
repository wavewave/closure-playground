{-# LANGUAGE BangPatterns       #-}
{-# LANGUAGE ExplicitNamespaces #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE TupleSections      #-}
{-# LANGUAGE TypeApplications   #-}

module Control.Distributed.Playground.MasterSlave where

import Control.Monad (forever)
import Control.Monad.Loops (whileJust_)
import Data.Foldable (traverse_)
import qualified Data.HashMap.Strict as HM
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Traversable (traverse)
import Network.Simple.TCP ( HostPreference(Host)
                          , type HostName
                          , type ServiceName
                          , Socket
                          , SockAddr
                          , connectSock
                          , closeSock
                          , serve
                          )
--
import Control.Distributed.Playground.Comm ( M
                                           , Msg
                                           , NodeName(..)
                                           , SocketPool(..)
                                           , fromMsg
                                           , toMsg
                                           , recvMsg
                                           , sendMsg
                                           , receiveChan
                                           , sendChan
                                           , newChan
                                           , newChanWithId
                                           , runManaged
                                           , logText
                                            )
import Control.Distributed.Playground.Request ( Request(..)
                                              , SomeRequest(..)
                                              , handleRequest
                                              )

-- | Main request handler in slave
requestHandler :: M r
requestHandler = do
  Just (_,rp_req) <- newChanWithId 0 -- fixed id = 0
  forever $ do
    SomeRequest req <- receiveChan rp_req
    let (sp_sp,sp_ans) = case req of
                           PureRequest _ sp_sp' sp_ans' -> (sp_sp',sp_ans')
                           MRequest    _ sp_sp' sp_ans' -> (sp_sp',sp_ans')
    (sp_input,rp_input) <- newChan
    logText $ "sp_input sent:"
    sendChan sp_sp sp_input
    whileJust_ (receiveChan rp_input) $ \input -> do
      logText $ "requested for input: " <> T.pack (show input)
      ans <- handleRequest req input
      logText $ "request handled with answer: " <> T.pack (show ans)
      sendChan sp_ans ans
      logText $ "answer sent"

slave :: NodeName -> HostName -> ServiceName -> IO ()
slave node hostName serviceName = do
  putStrLn "Waiting for connection from master."
  serve (Host hostName) serviceName $ \(sock, remoteAddr) -> do
    putStrLn $ "TCP connection established from " ++ show remoteAddr
    mname <- fmap (fromMsg :: Msg -> Text) <$> recvMsg sock
    case mname of
      Just name ->
        if name == "master"
          then do
            let pool = SocketPool $ HM.fromList [(NodeName name,(sock,remoteAddr))]
            TIO.putStrLn $ "Connected client is " <> name <> ". Start process!"
            runManaged node pool $ do
              -- forkIO $ peerNetworkHandler
              requestHandler
          else do
            -- placeholder for peer discovery.
            TIO.putStrLn $ "Connected client is " <> name <> ", but cannot handle it yet"
      Nothing -> error "should not happen"

establishConnection :: (String,ServiceName) -> IO (Socket,SockAddr)
establishConnection (host,port) = do
  (sock,sockAddr) <- connectSock host port
  sendMsg sock (toMsg ("master" :: Text))
  pure (sock,sockAddr)


master :: [(NodeName,(HostName,ServiceName))] -> M a -> IO a
master slaveList task = do
  pool <-
    SocketPool . HM.fromList <$>
      traverse (\(n,(h,s)) -> fmap (n,) (establishConnection (h,s))) slaveList

  -- threadDelay 2500000
  r <- runManaged (NodeName "master") pool task
  traverse_ (closeSock . fst) $ sockPoolMap pool
  pure r
