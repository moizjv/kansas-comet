{-# LANGUAGE OverloadedStrings, ScopedTypeVariables, KindSignatures, GADTs #-}

-- Example of using Kansas Comet

module Main where

import Data.Aeson as A hiding ((.=))
import Data.Aeson.Types as AP hiding ((.=))
import qualified Web.Scotty as Scotty
import Web.Scotty (scotty, get, file, literal, middleware, scottyApp)
import Web.Scotty.Comet as KC
import Data.Default
import Data.Map (Map)
import Control.Monad
import Control.Applicative ((<$>),(<*>))
import qualified Control.Applicative as A
import Control.Concurrent
import Control.Concurrent.STM
import Data.Semigroup
import Data.List as L
import Control.Monad.IO.Class
import Network.Wai.Middleware.Static
--import Network.Wai      -- TMP for debug
import qualified Network.WebSockets as WS
import qualified Data.Text.Lazy as LT
import qualified Data.Text      as T
import qualified Network.Wai.Handler.WebSockets as WaiWS
import Network.Wai.Handler.Warp
import Data.Maybe
import Data.Text.Lazy.Encoding
import Data.Text.Lazy

main :: IO ()
main = do
    putStrLn "Serving on http://localhost:3000"
    app <- scotty_app
    runSettings (setPort 3000 defaultSettings) $ WaiWS.websocketsOr WS.defaultConnectionOptions application app


--scotty_app :: IO Application
scotty_app = scottyApp $ do

        kcomet <- liftIO kCometPlugin

        let pol = only [ ("", "index.html")
                    --   , ("js/kansas-comet.js",kcomet)
                       , ("", "js/kansas-comet.js")
                       ]
                  <|> ((hasPrefix "css/" <|> hasPrefix "js/") >-> addBase ".")

        middleware $ staticPolicy pol

        connect opts web_app


opts :: KC.Options
opts = def { prefix = "/example", verbose = 3 }

-- This is run each time the page is first accessed
web_app :: Document -> IO ()
web_app doc = do
    send doc $ T.unlines
        [ "$('body').on('slide', '.slide', function (event,aux) {"
        , "$.kc.event({eventname: 'slide', count: aux.value });"
        , "});"
        ]
    send doc $ T.unlines
        [ "$('body').on('click', '.click', function (event,aux) {"
        , "$.kc.event({eventname: 'click', id: $(this).attr('id'), pageX: event.pageX, pageY: event.pageY });"
        , "});"
        ]
    forkIO $ control doc 0
    return ()

control :: Document -> Int -> IO ()
control doc model = do
    res <- atomically $ readTChan (eventQueue doc)
    case parse parseEvent res of
           Success evt -> case evt of
                   Slide n                        -> view doc n
                   Click "up"    _ _ | model < 25 -> view doc (model + 1)
                   Click "down"  _ _ | model > 0  -> view doc (model - 1)
                   Click "reset" _ _              -> view doc 0
                   _ -> control doc model
           _ -> control doc model

view :: Document -> Int -> IO ()
view doc n = do
    send doc $ T.unlines
                [ "$('#slider').slider('value'," <> T.pack(show n) <> ");"
                , "$('#fib-out').html('fib " <> T.pack(show n) <> " = ...')"
                ]
    -- sent a 2nd packet, because it will take time to compute fib
    send doc ("$('#fib-out').text('fib " <> T.pack(show n) <> " = " <> T.pack(show (fib n)) <> "')")

    control doc n

fib n = if n < 2 then 1 else fib (n-1) + fib (n-2)

parseEvent (Object v) = (do
                e :: String <- v .: "eventname"
                n <- v .: "count"
                if e == "slide" then return $ Slide n
                                else mzero) A.<|>
                                (do
                e :: String <- v .: "eventname"
                tag :: String <- v .: "id"
                x :: Int <- v .: "pageX"
                y :: Int <- v .: "pageY"
                if e == "click" then return $ Click tag x y
                                else mzero)
          -- A non-Object value is of the wrong type, so fail.
parseEvent _          = mzero


application :: WS.PendingConnection -> IO ()
application pending = do
    conn <- WS.acceptRequest pending
    putStrLn "Received request from webclient"
    msg::T.Text  <-  WS.receiveData conn
    putStrLn $ show msg
    WS.sendTextData conn $ T.unlines
        [ "$('body').on('slide', '.slide', function (event,aux) {"
        , "$.kc.eventWebsocket({eventname: 'slide', count: aux.value });"
        , "});"
        ]
    WS.sendTextData conn $ T.unlines
        [ "$('body').on('click', '.click', function (event,aux) {"
        , "$.kc.eventWebsocket({eventname: 'click', id: $(this).attr('id'), pageX: event.pageX, pageY: event.pageY });"
        , "});"
        ]
    webSocketControl conn 0

webSocketControl conn model = do
    evnt <- WS.receiveData conn
  --  putStrLn $ show $ decode' evnt
    let val = fromJust $ decode' evnt
    putStrLn $ show val
    case parse parseEvent val of
           Success evt -> case evt of
                   Slide n                        -> viewSocket conn n
                   Click "up"    _ _ | model < 25 -> viewSocket conn (model + 1)
                   Click "down"  _ _ | model > 0  -> viewSocket conn (model - 1)
                   Click "reset" _ _              -> viewSocket conn 0
                   _ -> webSocketControl conn model
           _ -> webSocketControl conn model


--view :: Document -> Int -> IO ()
viewSocket conn n = do
    WS.sendTextData conn $ T.unlines
                [ "$('#slider').slider('value'," <> T.pack(show n) <> ");"
                , "$('#fib-out').html('fib " <> T.pack(show n) <> " = ...')"
                ]
    -- sent a 2nd packet, because it will take time to compute fib
    WS.sendTextData conn ("$('#fib-out').text('fib " <> T.pack(show n) <> " = " <> T.pack(show (fib n)) <> "')")

    webSocketControl conn n


data Event = Slide Int
           | Click String Int Int
    deriving (Show)
