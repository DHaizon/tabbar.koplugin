local DateTimeWidget = require("ui/widget/datetimewidget")
local InfoMessage = require("ui/widget/infomessage")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local NavigationTabs = require("navigationtabs")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local TopContainer = require("ui/widget/container/topcontainer")
local EventListener = require("ui/widget/eventlistener")
local logger = require("logger")
local datetime = require("datetime")
local Event = require("ui/event")
local Device = require("device")
local Screen = Device.screen
local _ = require("gettext")
local T = require("ffi/util").template
local Size = require("ui/size")
local Font = require("ui/font")
local Dispatcher = require("dispatcher")

local ID_MENU = "menu"
local ID_ADD = "add"
local ID_REORDER = "reorder"

-- These three variables must live at module level, not in self, because
-- KoReader creates a new TabbedReader instance each time a document is opened.
-- Keeping them here lets tab state survive across document switches, which is
-- what makes multi-book tabs work: pressing + then opening a file from the
-- explorer should land in the new tab, not reset everything.
local tabs = {}
local selected_tab_index = 1
local opening_book = nil

local TabbedReader = EventListener:extend {
    name = "tabbar",
    max_tabs = 10,
    button_width = nil, -- The width of the add, bookmark and menu buttons. Must be whole.
                        -- Defaults to the bar's height, which creates square buttons.
}

function TabbedReader:new(o)
    o = self:extend(o)
    if o._init then o:_init() end
    if o.init then o:init() end
    return o
end

function TabbedReader:onDispatcherRegisterActions()
    Dispatcher:registerAction("tabbar_toggle_bar", {
        category = "none",
        event    = "ToggleTabBar",
        title    = _("Tabbed Reader: Toggle Tab Bar"),
        desc     = _("Show or hide the tab bar"),
        general  = true,
    })
end

function TabbedReader:onToggleTabBar()
    self:toggleBar()
    return true
end

function TabbedReader:init()
    self:onDispatcherRegisterActions()
    -- Width is based on the text's height (to get a square button). See TextBoxWidget:init(). Multiplied by 1.2 because of the padding.
    self.button_width = self.button_width or math.floor((1 + 0.3) * Font:getFace("x_smalltfont").size * 1.2)
    self.ui.menu:registerToMainMenu(self)

    -- tabs, selected_tab_index and opening_book are intentionally module-level
    -- (see declaration above) so they survive across document switches.
    -- Instance-only state lives in self:
    --
    -- FIX: Read is_bar_visible from G_reader_settings so the preference
    -- persists across document switches and KoReader restarts.
    -- G_reader_settings is a KoReader global injected by the framework.
    self.is_bar_visible = G_reader_settings:readSetting("tabbar_bar_visible", true)
    self.readerReady = false
    self.current_page = 1
    self.current_chapter = nil
    self.current_book_file = nil
    self.current_book_title = nil
    logger.dbg("TabbedReader: loaded. Button width: ", self.button_width)
end

function TabbedReader:tabsToStr()
    local tabs_table = "\nId | Page | Chapter | Book Title | Book Path\n===============================\n"

    for k, v in ipairs(tabs) do
        tabs_table = tabs_table ..
            k .. " | " .. v.page .. " | " .. v.chapter .. " | " .. (v.book_title or "Unknown") .. " | " .. v.book_file .. "\n"
    end

    return tabs_table
end

function TabbedReader:onReaderReady(doc_settings)
    -- FIX: Collapsed the three redundant identical guards into one.
    if not self.is_bar_visible or not doc_settings then
        return
    end

    -- Re-register dispatcher action each time a document opens (mirrors
    -- pinnedelements pattern, ensures the action survives plugin reloads).
    self:onDispatcherRegisterActions()

    self.current_book_file = doc_settings.data.doc_path
    self.current_book_title = doc_settings.data.doc_props.title
    logger.dbg("TabbedReader: ", "path", doc_settings.data.doc_path)
    logger.dbg("TabbedReader: ", "title", doc_settings.data.doc_props.title)

    logger.dbg("TabbedReader:onReaderReady", self:tabsToStr())

    if #tabs < 1 then
        -- Create the first tab
        tabs[1] = {
            page = self.current_page,
            chapter = self.current_chapter,
            book_file = self.current_book_file,
            book_title = self.current_book_title,
        }
        selected_tab_index = 1
    end

    local buttons = self:buildButtons()

    local nav_selected = tabs[selected_tab_index]

    if nav_selected.book_file == self.current_book_file then
        -- Only change page if it's the same book
        if nav_selected.page and nav_selected.page ~= self.current_page then
            logger.dbg("TabbedReader: ", "onReaderReady GotoPage", nav_selected.page)
            self.ui:handleEvent(Event:new("GotoPage", nav_selected.page))
        end
    end

    if nav_selected.book_file and nav_selected.book_file ~= self.current_book_file then
        if opening_book then
            logger.dbg("TabbedReader: ", "ERROR - wrong book. Expected: ", nav_selected.book_file, "actual:",
                self.current_book_file)
        else
            -- Book opened from the file explorer
            nav_selected.page = self.current_page -- reset page info as it's a new book
            nav_selected.chapter = self.current_chapter
            nav_selected.book_file = self.current_book_file
            nav_selected.book_title = self.current_book_title
        end
    end

    opening_book = nil

    self.button_dialog = NavigationTabs:new {
        buttons = buttons,
        -- FIX: Force full screen width so that NavigationTabs:initGesListener
        -- touch zones align with the visual bar in all orientations.
        -- By default, NavigationTabs uses math.min(width, height) which in
        -- landscape makes the bar narrower than the screen. CenterContainer
        -- then offsets it visually, but initGesListener starts touch zones
        -- from ratio_x=0, causing a mismatch between visual and touch areas.
        width = Screen:getWidth(),
        callback = function(button_id, ges)
            self:navigationCallback(button_id, ges)
        end,
    }
    self.ui.view:registerViewModule("button_dialog", self.button_dialog)
    self.button_dialog:initGesListener()
    self.button_dialog:setSelected(self:getIdForButton(selected_tab_index))
    logger.dbg("TabbedReader: ", selected_tab_index, self.current_page, self.current_chapter)
    self.readerReady = true
end

function TabbedReader:getIdForButton(index)
    return "tab_" .. index
end

function TabbedReader:getIndexForButton(id)
    local prefix = "tab_"
    if string.sub(id, 1, #prefix) == prefix then
        local index_str = string.sub(id, #prefix + 1)
        local index = tonumber(index_str)
        return index
    end
    return nil
end

function TabbedReader:buildButtons()
    local buttons = {}

    buttons[1] = {
        icon = "appbar.menu",
        icon_width = self.button_width,
        icon_height = self.button_width,
        id = ID_MENU,
        width = self.button_width,
        unselectable = true
    }

    for i, nav_entry in ipairs(tabs) do
        local id = self:getIdForButton(i)
        buttons[i + 1] = {
            text_func = function()
                logger.dbg("TabbedReader: ", "nav_entry", id, nav_entry, nav_entry and nav_entry.chapter)
                if nav_entry then
                    if nav_entry.book_title and nav_entry.chapter then
                        return nav_entry.book_title .. ": " .. nav_entry.chapter
                    end
                    return nav_entry.book_title or nav_entry.chapter or "Tab " .. i
                end
                return "Tab " .. i
            end,
            id = id,
        }
    end

    local index = #tabs + 2

    if #tabs < self.max_tabs then
        buttons[index] = {
            text = "+",
            id = ID_ADD,
            width = self.button_width,
            unselectable = true,
        }
        index = index + 1
    end

    buttons[index] = {
        text = "⇅",
        id = ID_REORDER,
        width = self.button_width,
        unselectable = true,
    }

    return { buttons }
end

function TabbedReader:reloadLayout()
    local buttons = self:buildButtons()
    self.button_dialog:unRegisterGesListener()
    self.button_dialog:reloadButtons(buttons)
    self.button_dialog:initGesListener()
    self.button_dialog:setSelected(self:getIdForButton(selected_tab_index))
end

function TabbedReader:showReorderMenu()
    -- Build one row per tab with ▲ and ▼ buttons to move it.
    -- The active tab follows its position after every move.
    local function makeButtons()
        local rows = {}
        for i, tab in ipairs(tabs) do
            local label = (tab.book_title or "?")
            if tab.chapter and tab.chapter ~= "" then
                label = label .. ": " .. tab.chapter
            end
            if i == selected_tab_index then
                label = "▶ " .. label
            end

            local idx = i -- capture for closures
            rows[#rows + 1] = {
                {
                    text = "▲",
                    enabled = (idx > 1),
                    callback = function()
                        -- swap tab with the one above
                        tabs[idx], tabs[idx - 1] = tabs[idx - 1], tabs[idx]
                        if selected_tab_index == idx then
                            selected_tab_index = idx - 1
                        elseif selected_tab_index == idx - 1 then
                            selected_tab_index = idx
                        end
                        UIManager:close(self.reorder_dialog)
                        self:reloadLayout()
                        self:showReorderMenu()
                    end,
                },
                {
                    text = label,
                    enabled = false, -- label only, not tappable
                },
                {
                    text = "▼",
                    enabled = (idx < #tabs),
                    callback = function()
                        -- swap tab with the one below
                        tabs[idx], tabs[idx + 1] = tabs[idx + 1], tabs[idx]
                        if selected_tab_index == idx then
                            selected_tab_index = idx + 1
                        elseif selected_tab_index == idx + 1 then
                            selected_tab_index = idx
                        end
                        UIManager:close(self.reorder_dialog)
                        self:reloadLayout()
                        self:showReorderMenu()
                    end,
                },
            }
        end
        -- Close button at the bottom
        rows[#rows + 1] = {
            {
                text = _("Close"),
                callback = function()
                    UIManager:close(self.reorder_dialog)
                end,
            },
        }
        return rows
    end

    self.reorder_dialog = ButtonDialog:new {
        title = _("Reorder Tabs"),
        buttons = makeButtons(),
    }
    UIManager:show(self.reorder_dialog)
end

function TabbedReader:navigationTapCallback(button_id)
    local tab_index = self:getIndexForButton(button_id)

    if tab_index == nil or tab_index < 1 or tab_index > #tabs then
        logger.warn("TabbedReader: ", "navigationTapCallback", "invalid tab index", button_id, tab_index)
        return
    end

    logger.dbg("TabbedReader: ", "navigationTapCallback", selected_tab_index, button_id, tab_index, tabs[tab_index].page)

    selected_tab_index = tab_index

    local new_file = tabs[tab_index].book_file
    local new_page = tabs[tab_index].page

    if new_file ~= nil and new_file ~= self.current_book_file then
        opening_book = new_file
        self.ui:showReader(new_file, nil, true)
    else
        logger.dbg("TabbedReader: ", "GotoPage", new_page)
        self.ui:handleEvent(Event:new("GotoPage", new_page))
    end

    self.button_dialog:setSelected(self:getIdForButton(selected_tab_index))
end

function TabbedReader:closeTab(tab_index)
    -- FIX: Changed #tabs < 1 to #tabs <= 1 to prevent removing the last tab
    -- and leaving the plugin in a broken state.
    if #tabs <= 1 then
        logger.warn("TabbedReader: ", "closeTab", "can't close the last tab")
        return
    end

    logger.dbg("TabbedReader: ", "closeTab", tab_index)

    table.remove(tabs, tab_index)
    if selected_tab_index == tab_index and selected_tab_index ~= 1 then
        selected_tab_index = selected_tab_index - 1
    end
    self:reloadLayout()
end

-- FIX: Removed empty navigationHoldCallback stub. Hold gestures on tabs are
-- now silently ignored. Re-add this function if hold behavior is implemented.

function TabbedReader:showMenu()
    local toggle_button = {
        text = _("Hide Tab Bar"),
        callback = function()
            self.dialog:onClose()
            self:toggleBar()
        end,
    }

    local close_tab_button = {
        text = _("Close Tab"),
        callback = function()
            self.dialog:onClose()
            self:closeTab(selected_tab_index)
        end,
        enabled = (#tabs > 1),
    }

    self.dialog = ButtonDialog:new {
        title = _("Tabs Menu"),
        buttons = {
            { toggle_button },
            { close_tab_button },
        },
    }
    UIManager:show(self.dialog)
end

function TabbedReader:addTab()
    -- Creates a new tab duplicating the current position.
    -- To open a different book in the new tab, use the file explorer after switching to it.
    tabs[#tabs + 1] = {
        page = self.current_page,
        chapter = self.current_chapter,
        book_file = self.current_book_file,
        book_title = self.current_book_title,
    }
end

function TabbedReader:navigationCallback(button_id, ges)
    if button_id == ID_MENU then
        logger.dbg("TabbedReader: ", "Menu pressed")
        self:showMenu()
        return
    end

    if button_id == ID_ADD then
        logger.dbg("TabbedReader: ", "Add pressed")
        if #tabs >= self.max_tabs then
            logger.dbg("TabbedReader: ", "Max tabs reached")
            return
        end
        self:addTab()
        self:reloadLayout()
        self:navigationTapCallback(self:getIdForButton(#tabs)) -- Switch to the new tab
        return
    end

    if button_id == ID_REORDER then
        logger.dbg("TabbedReader: ", "Reorder pressed")
        if #tabs > 1 then
            self:showReorderMenu()
        end
        return
    end

    if ges.ges == "tap" then
        self:navigationTapCallback(button_id)
        return
    end

    -- Hold gesture: no behavior defined yet. Add navigationHoldCallback here if needed.
    if ges.ges == "hold" then
        return
    end
end

function TabbedReader:onCloseDocument()
end

function TabbedReader:onPageUpdate(page)
    self.current_page = page
    self.current_chapter = self.ui.toc:getTocTitleOfCurrentPage()

    if #tabs < selected_tab_index then
        return
    end

    tabs[selected_tab_index].page = self.current_page
    tabs[selected_tab_index].chapter = self.current_chapter

    if self.readerReady and self.is_bar_visible and self.button_dialog then
        self.button_dialog:refreshButton(self:getIdForButton(selected_tab_index))
    end
end

-- FIX: onPosUpdate now mirrors onPageUpdate so that reflowable EPUB documents
-- (which emit pos updates instead of page updates) also keep tab state current.
function TabbedReader:onPosUpdate(pos)
    logger.dbg("TabbedReader: onPosUpdate", pos)

    if not pos then return end

    -- pos is a string like "page.pos" or similar; store it as the current position.
    -- Chapter info is still sourced from the TOC.
    self.current_page = pos
    self.current_chapter = self.ui.toc:getTocTitleOfCurrentPage()

    if #tabs < selected_tab_index then
        return
    end

    tabs[selected_tab_index].page = self.current_page
    tabs[selected_tab_index].chapter = self.current_chapter

    if self.readerReady and self.is_bar_visible and self.button_dialog then
        self.button_dialog:refreshButton(self:getIdForButton(selected_tab_index))
    end
end

function TabbedReader:addToMainMenu(menu_items)
    menu_items.tabbar_toggle = {
        text = _("Tabbed Reader bar"),
        checked_func = function() return self.is_bar_visible end,
        callback = function()
            self:toggleBar()
        end,
        sorting_hint = "more_tools",
    }
end

function TabbedReader:onResume()
end

-- FIX: Pass self.ui.doc_settings to onReaderReady so it receives a valid
-- doc_settings table instead of nil, which would cause a crash on field access.
-- FIX: Defer the reinitialization with scheduleIn(0) so it runs in the next
-- UI cycle, after Screen:getWidth()/getHeight() reflect the new orientation.
-- Without the defer, initGesListener bakes touch zone coordinates using the
-- old screen dimensions, causing a mismatch between the visual bar position
-- (painted with new dims) and the actual touch zones (calculated with old dims).
function TabbedReader:onSetDimensions(dimen)
    logger.dbg("TabbedReader: ", "onSetDimensions main")
    if self.readerReady and self.ui.doc_settings then
        local doc_settings = self.ui.doc_settings
        UIManager:scheduleIn(0, function()
            if self.readerReady then
                self:onReaderReady(doc_settings)
            end
        end)
    end
end

-- FIX: Removed duplicate TabbedReader:Bar() function. All toggle logic is
-- consolidated here in toggleBar().
function TabbedReader:toggleBar()
    self.is_bar_visible = not self.is_bar_visible

    -- Persist the preference so it survives document switches and restarts.
    G_reader_settings:saveSetting("tabbar_bar_visible", self.is_bar_visible)

    if not self.is_bar_visible then
        -- 1. Unregister touch zones so the bar stops intercepting input.
        if self.button_dialog then
            self.button_dialog:unRegisterGesListener()
        end

        -- 2. Remove from the view pipeline so paintTo is no longer called.
        --    NOTE: unRegisterViewModule does not exist in this version of
        --    readerview.lua — registerViewModule just sets view_modules[name],
        --    so we remove it by setting it to nil directly.
        if self.ui.view and self.ui.view.view_modules then
            self.ui.view.view_modules["button_dialog"] = nil
        end

        -- 3. Trigger repaint. We call onCloseWidget first so it queues a
        --    "flashui" dirty over the bar's exact dimen, then we also dirty
        --    self.ui (ReaderUI) with "full" so the document repaints underneath.
        --    Both are needed: onCloseWidget handles the bar region, setDirty on
        --    self.ui forces the document layer to redraw over that area.
        if self.button_dialog then
            if self.button_dialog.onCloseWidget then
                self.button_dialog:onCloseWidget()
            end
            self.button_dialog:free()
            self.button_dialog = nil
        end

        self.readerReady = false

        UIManager:setDirty(self.ui, "full")
    else
        -- 4. Rebuild the bar only if a document is open.
        if self.ui.doc_settings then
            self:onReaderReady(self.ui.doc_settings)
        end
        -- 5. Force a repaint so the bar appears immediately without needing
        --    a page turn or other UI event to trigger a redraw.
        UIManager:setDirty(self.ui, "full")
    end

    return true
end

return TabbedReader