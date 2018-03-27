{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Termonad where

import Termonad.Prelude

import Control.Lens (imap)
import Data.Unique (Unique, newUnique)
import qualified GI.Gdk as Gdk
import GI.Gdk
  ( AttrOp((:=))
  , EventKey
  , pattern KEY_1
  , pattern KEY_2
  , pattern KEY_3
  , pattern KEY_4
  , pattern KEY_5
  , pattern KEY_6
  , pattern KEY_7
  , pattern KEY_8
  , pattern KEY_9
  , pattern KEY_T
  , ModifierType(..)
  , get
  , new
  , screenGetDefault
  )
import GI.Gio (ApplicationFlags(ApplicationFlagsFlagsNone), applicationRun, noCancellable)
import GI.GLib.Flags (SpawnFlags(..))
import GI.Gtk
  ( Application
  , ApplicationWindow
  , Box(Box)
  , CssProvider(CssProvider)
  , Notebook(Notebook)
  , Orientation(..)
  , ScrolledWindow(ScrolledWindow)
  , pattern STYLE_PROVIDER_PRIORITY_APPLICATION
  , applicationNew
  , applicationWindowNew
  , mainQuit
  , noWidget
  , styleContextAddProviderForScreen
  )
import qualified GI.Gtk as Gtk
import GI.Pango
  ( FontDescription
  , pattern SCALE
  , fontDescriptionNew
  , fontDescriptionSetFamily
  , fontDescriptionSetSize
  )
import GI.Vte (CursorBlinkMode(..), PtyFlags(..), Terminal(Terminal))
import Text.XML.QQ (Document, xmlRaw)

uiDoc :: Document
uiDoc =
  [xmlRaw|
      <ui>
        <menubar name='MenuBar'>
          <menu action='FileMenu'>
            <menuitem action='FileNewTab'/>
            <separator />
            <menuitem action='FileQuit' />
          </menu>
          <menu action='EditMenu'>
            <menuitem action='EditCopy' />
            <menuitem action='EditPaste' />
          </menu>
        </menubar>
      </ui>
   |]

-- ui ::

data Term = Term
  { term :: Terminal
  , unique :: Unique
  }

data Note = Note
  { notebook :: Notebook
  , children :: [Term]
  , font :: FontDescription
  }

type TerState = MVar Note

instance Eq Term where
  (==) :: Term -> Term -> Bool
  (==) = ((==) :: Unique -> Unique -> Bool) `on` (unique :: Term -> Unique)

showKeys :: EventKey -> IO Bool
showKeys eventKey = do
  eventType <- get eventKey #type
  maybeString <- get eventKey #string
  modifiers <- get eventKey #state
  len <- get eventKey #length
  keyval <- get eventKey #keyval
  isMod <- get eventKey #isModifier
  keycode <- get eventKey #hardwareKeycode

  putStrLn "key press event:"
  putStrLn $ "  type = " <> tshow eventType
  putStrLn $ "  str = " <> tshow maybeString
  putStrLn $ "  mods = " <> tshow modifiers
  putStrLn $ "  isMod = " <> tshow isMod
  putStrLn $ "  len = " <> tshow len
  putStrLn $ "  keyval = " <> tshow keyval
  putStrLn $ "  keycode = " <> tshow keycode
  putStrLn ""

  pure True

removeTerm :: [Term] -> Term -> [Term]
removeTerm terms terminal = delete terminal terms

data Key = Key
  { keyVal :: Word32
  , keyMods :: Set ModifierType
  } deriving (Eq, Ord, Show)

toKey :: Word32 -> Set ModifierType -> Key
toKey = Key

stopProp :: (TerState -> IO a) -> TerState -> IO Bool
stopProp callback terState = callback terState $> True

keyMap :: Map Key (TerState -> IO Bool)
keyMap =
  let numKeys =
        [ KEY_1
        , KEY_2
        , KEY_3
        , KEY_4
        , KEY_5
        , KEY_6
        , KEY_7
        , KEY_8
        , KEY_9
        ]
      altNumKeys =
        imap
          (\i k ->
             (toKey k [ModifierTypeMod1Mask], stopProp (altNumSwitchTerm i))
          )
          numKeys
  in
  mapFromList $
    [ ( toKey KEY_T [ModifierTypeControlMask, ModifierTypeShiftMask]
      , stopProp createTerm
      )
    ] <>
    altNumKeys

altNumSwitchTerm :: Int -> TerState -> IO ()
altNumSwitchTerm i terState = do
  Note{..} <- readMVar terState
  void $ #setCurrentPage notebook (fromIntegral i)

focusTerm :: Term -> IO ()
focusTerm Term{..} =
  Gdk.set term [#hasFocus := True]

termExit :: ScrolledWindow -> Term -> TerState -> Int32 -> IO ()
termExit scrolledWin terminal terState _exitStatus =
  modifyMVar_ terState $ \Note{..} -> do
    #detachTab notebook scrolledWin
    pure $ Note notebook (removeTerm children terminal) font

createScrolledWin :: IO ScrolledWindow
createScrolledWin = do
  scrolledWin <- new ScrolledWindow []
  #show scrolledWin
  pure scrolledWin

createTerm :: TerState -> IO Term
createTerm terState = do
  scrolledWin <- createScrolledWin
  fontDesc <- withMVar terState (pure . font)
  vteTerm <-
    new Terminal [#fontDesc := fontDesc, #cursorBlinkMode := CursorBlinkModeOn]
  _termResVal <-
    #spawnSync
      vteTerm
      [PtyFlagsDefault]
      Nothing
      ["/usr/bin/env", "bash"]
      Nothing
      [SpawnFlagsDefault]
      Nothing
      noCancellable
  #show vteTerm
  uniq' <- newUnique
  let terminal = Term vteTerm uniq'
  #add scrolledWin (term terminal)
  modifyMVar_ terState $ \Note{..} -> do
    pageIndex <- #appendPage notebook scrolledWin noWidget
    void $ #setCurrentPage notebook pageIndex
    pure $ Note notebook (snoc children terminal) font
  void $ Gdk.on vteTerm #windowTitleChanged $ do
    title <- get vteTerm #windowTitle
    Note{..} <- readMVar terState
    #setTabLabelText notebook scrolledWin title
  void $ Gdk.on (term terminal) #keyPressEvent $ handleKeyPress terState
  void $ Gdk.on scrolledWin #keyPressEvent $ handleKeyPress terState
  void $ Gdk.on (term terminal) #childExited $ termExit scrolledWin terminal terState
  pure terminal

handleKeyPress :: TerState -> EventKey -> IO Bool
handleKeyPress terState eventKey = do
  keyval <- get eventKey #keyval
  modifiers <- get eventKey #state
  let key = toKey keyval (setFromList modifiers)
      maybeAction = lookup key keyMap
  case maybeAction of
    Just action -> action terState
    Nothing -> pure False

indexOf :: forall a. Eq a => a -> [a] -> Maybe Int
indexOf a = go 0
  where
    go :: Int -> [a] -> Maybe Int
    go _ [] = Nothing
    go i (h:ts) = if h == a then Just i else go (i + 1) ts

defaultMain1 :: ApplicationWindow -> IO ()
defaultMain1 win = do
  -- void $ Gtk.init Nothing
  maybeScreen <- screenGetDefault
  case maybeScreen of
    Nothing -> pure ()
    Just screen -> do
      cssProvider <- new CssProvider []
      let (textLines :: [Text]) =
            [ "scrollbar {" :: Text
            , "  -GtkRange-slider-width: 200px;"
            , "  -GtkRange-stepper-size: 200px;"
            , "  border-width: 200px;"
            , "  background-color: #ff0000;"
            , "  color: #ff0000;"
            , "  min-width: 50px;"
            , "}"
            -- , "scrollbar trough {"
            -- , "  -GtkRange-slider-width: 200px;"
            -- , "  -GtkRange-stepper-size: 200px;"
            -- , "  border-width: 200px;"
            -- , "  background-color: #00ff00;"
            -- , "  color: #00ff00;"
            -- , "  min-width: 50px;"
            -- , "}"
            -- , "scrollbar slider {"
            -- , "  -GtkRange-slider-width: 200px;"
            -- , "  -GtkRange-stepper-size: 200px;"
            -- , "  border-width: 200px;"
            -- , "  background-color: #0000ff;"
            -- , "  color: #0000ff;"
            -- , "  min-width: 50px;"
            -- , "}"
            ]
      let styleData = encodeUtf8 (unlines textLines :: Text)
      #loadFromData cssProvider styleData
      styleContextAddProviderForScreen
        screen
        cssProvider
        (fromIntegral STYLE_PROVIDER_PRIORITY_APPLICATION)
  -- win <- new Gtk.Window [#title := "Hi there"]
  void $ Gdk.on win #destroy mainQuit


  box <- new Box [#orientation := OrientationVertical]

  fontDesc <- fontDescriptionNew
  fontDescriptionSetFamily fontDesc "DejaVu Sans Mono"
  -- fontDescriptionSetFamily font "Source Code Pro"
  fontDescriptionSetSize fontDesc (16 * SCALE)

  note <- new Notebook [#canFocus := False]
  #packStart box note True True 0

  terState <-
    newMVar $
      Note
        { notebook = note
        , children = []
        , font = fontDesc
        }

  void $ Gdk.on note #pageRemoved $ \_ _ -> do
    pages <- #getNPages note
    when (pages == 0) mainQuit

  terminal <- createTerm terState

  #add win box
  -- #showAll win
  focusTerm terminal
  -- Gtk.main

appActivate :: Application -> IO ()
appActivate app = do
  appWin <- applicationWindowNew app
  defaultMain1 appWin
  #present appWin

appStartup :: Application -> IO ()
appStartup _app = pure ()
  -- this is probably where I should create actions and builders

defaultMain :: IO ()
defaultMain = do
  app <- applicationNew (Just "termonad") [ApplicationFlagsFlagsNone]
  void $ Gdk.on app #startup (appStartup app)
  void $ Gdk.on app #activate (appActivate app)
  void $ applicationRun app Nothing
