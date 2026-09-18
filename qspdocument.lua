-- qspdocument.lua
-- Фиктивный document provider для регистрации .qsp в FileManager.
-- Реально ничего не открывает — открытие идёт через QSPWidget.
local Document = require("document/document")
local Geom = require("ui/geometry")

local QSPDocument = Document:extend{
    provider = "qsp",
    provider_name = "QSP",
}

function QSPDocument:init() end
function QSPDocument:getPageCount() return 1 end
function QSPDocument:getNativePageDimensions() return Geom:new{ w = 1, h = 1 } end
function QSPDocument:getPageDimensions() return Geom:new{ w = 1, h = 1 } end
function QSPDocument:renderPage() end
function QSPDocument:getToc() return {} end
function QSPDocument:close() end

return QSPDocument