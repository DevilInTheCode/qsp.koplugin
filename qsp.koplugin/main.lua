local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local DocumentRegistry = require("document/documentregistry")
local _ = require("gettext")
local logger = require("logger")
local QSPDocument = require("qspdocument")
local QSPWidget = require("qspwidget")

local QSP = WidgetContainer:extend{
    name = "qsp",
    is_doc_only = false,
}

function QSP:init()
    logger.dbg("QSP: init() called")

    -- 1. Регистрируем .qsp как известное расширение
    DocumentRegistry:addProvider("qsp", "application/x-qsp", QSPDocument, 100)

    -- 2. Регистрируем aux-provider (перезапишет QSPDocument в known_providers)
    DocumentRegistry:addAuxProvider({
        provider = "qsp",
        order = 100,
    })

    -- 3. Устанавливаем ассоциацию: .qsp → qsp (aux-provider)
    local providers = G_reader_settings:readSetting("provider", {})
    providers["qsp"] = "qsp"
    G_reader_settings:saveSetting("provider", providers)

    -- 4. Добавляем пункт в меню
    self.ui.menu:registerToMainMenu(self)

    logger.dbg("QSP: init() done")
end

function QSP:addToMainMenu(menu_items)
    menu_items.qsp_open = {
        text = _("Открыть QSP-игру"),
        sorting_hint = "tools",
        callback = function()
            self:openQSPFile()
        end,
    }
end

function QSP:openQSPFile()
    local FileChooser = require("ui/widget/filechooser")
    local filechooser = FileChooser:new{
        select_file = true,
        select_directory = false,
        show_all_files = false,
        file_filter = function(filename)
            return filename:lower():match("%.qsp$") ~= nil
        end,
        title = _("Выберите QSP-файл"),
        path = "/mnt/us/QSP",
        onConfirm = function(file)
            UIManager:close(filechooser)
            local widget = QSPWidget:new{ file = file }
            UIManager:show(widget)
        end,
    }
    UIManager:show(filechooser)
end

-- Этот метод вызовет FileManager:openFile, когда пользователь тапнет .qsp
function QSP:openFile(file)
    logger.dbg("QSP: openFile() called with:", file)

    if not file then
        logger.warn("QSP: openFile called without file")
        return false
    end

    local widget = QSPWidget:new{ file = file }
    UIManager:show(widget)
    return true
end

return QSP