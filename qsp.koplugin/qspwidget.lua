local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ffi = require("ffi")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

-- FFI: API libqsp (QSP_CHAR = int = 4 байта, UTF-32!)
ffi.cdef[[
    typedef int QSP_CHAR;
    typedef int QSP_BOOL;

    typedef struct { QSP_CHAR *Str; QSP_CHAR *End; } QSPString;
    typedef struct { QSPString Name; QSPString Image; } QSPListItem;
    typedef struct { QSPString Name; QSPString Title; QSPString Image; } QSPObjectItem;
    typedef struct { int LineNum; QSPString Line; } QSPLineInfo;

    void QSPInit(void);
    void QSPTerminate(void);
    QSP_BOOL QSPLoadGameWorldFromData(const void *data, int dataSize, QSP_BOOL isNewGame);
    QSP_BOOL QSPRestartGame(QSP_BOOL toRefreshUI);
    QSPString QSPGetMainDesc(void);
    int QSPGetActions(QSPListItem *items, int itemsBufSize);
    QSP_BOOL QSPSetSelActionIndex(int ind, QSP_BOOL toRefreshUI);
    QSP_BOOL QSPExecuteSelActionCode(QSP_BOOL toRefreshUI);
    QSP_BOOL QSPExecString(QSPString str, QSP_BOOL toRefreshUI);
    int QSPGetObjects(QSPObjectItem *items, int itemsBufSize);
    QSP_BOOL QSPSetSelObjectIndex(int ind, QSP_BOOL toRefreshUI);
    int QSPGetSelObjectIndex(void);
    int QSPGetActionCode(int actionIndex, QSPLineInfo *lines, int linesBufSize);
]]

-- UTF-32 → UTF-8
local function qspStringToUtf8(qsp_str)
    if qsp_str.Str == nil or qsp_str.End == nil then return "" end
    local len = tonumber(ffi.cast("intptr_t", qsp_str.End) - ffi.cast("intptr_t", qsp_str.Str))
    len = len / 4
    local result = {}
    for i = 0, len - 1 do
        local code = tonumber(qsp_str.Str[i])
        if code == 0 then break end
        if code < 0x80 then
            result[#result + 1] = string.char(code)
        elseif code < 0x800 then
            result[#result + 1] = string.char(
                0xC0 + math.floor(code / 0x40),
                0x80 + (code % 0x40)
            )
        elseif code < 0x10000 then
            result[#result + 1] = string.char(
                0xE0 + math.floor(code / 0x1000),
                0x80 + math.floor((code % 0x1000) / 0x40),
                0x80 + (code % 0x40)
            )
        else
            result[#result + 1] = string.char(
                0xF0 + math.floor(code / 0x40000),
                0x80 + math.floor((code % 0x40000) / 0x1000),
                0x80 + math.floor((code % 0x1000) / 0x40),
                0x80 + (code % 0x40)
            )
        end
    end
    return table.concat(result)
end

local function makeQSPString(s)
    local buf = ffi.new("int[?]", #s + 1)
    for i = 1, #s do
        buf[i - 1] = s:byte(i)
    end
    buf[#s] = 0
    return ffi.new("QSPString", buf, buf + #s)
end

local function getPluginDir()
    local info = debug.getinfo(1, "S")
    local source = info.source
    local path = source:sub(2)
    return path:match("(.+)/[^/]+$")
end

local function loadQSPLib()
    local plugin_dir = getPluginDir()
    local candidates = {
        plugin_dir .. "/libs/armv7/libqsp.so",
        plugin_dir .. "/libs/libqsp.so",
        "libqsp",
    }
    for _, path in ipairs(candidates) do
        if path:match("%.so$") then
            local f = io.open(path, "rb")
            if not f then goto continue end
            f:close()
        end
        local ok, lib = pcall(ffi.load, path)
        if ok then
            return lib
        end
        ::continue::
    end
    return nil
end

-- ============================================================
-- QSPWidget
-- ============================================================

local QSPWidget = InputContainer:extend{
    file = nil,
    lib = nil,
    loaded = false,
    desc_html = "",
    actions = {},
    objects = {},
    font_size = 28,
    html_widget = nil,
}

function QSPWidget:init()
    self.lib = loadQSPLib()
    if not self.lib then
        UIManager:show(InfoMessage:new{
            text = _("Не удалось загрузить libqsp.so"),
        })
        return
    end

    self.lib.QSPInit()

    local f = io.open(self.file, "rb")
    if not f then
        UIManager:show(InfoMessage:new{
            text = _("Не удалось открыть файл: ") .. tostring(self.file),
        })
        return
    end
    local data = f:read("*all")
    f:close()

    local buf = ffi.new("char[?]", #data)
    ffi.copy(buf, data, #data)

    if self.lib.QSPLoadGameWorldFromData(buf, #data, 1) == 0 then
        UIManager:show(InfoMessage:new{
            text = _("Ошибка загрузки QSP-игры"),
        })
        return
    end

    self.lib.QSPRestartGame(1)

    self.loaded = true
    self:updateState()
    self:buildLayout()

    -- Поглощаем свайпы, чтобы UIManager не закрыл виджет
    self.ges_events = {
        SwipeIgnore = {
            GestureRange:new{
                ges = "swipe",
                range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() },
            },
        },
    }
end

function QSPWidget:updateState()
    if not self.loaded then return end

    self.desc_html = qspStringToUtf8(self.lib.QSPGetMainDesc())

    self.actions = {}
    local items = ffi.new("QSPListItem[?]", 100)
    local count = self.lib.QSPGetActions(items, 100)
    for i = 0, count - 1 do
        local name = qspStringToUtf8(items[i].Name)
        local is_active = true

        local lines = ffi.new("QSPLineInfo[?]", 100)
        local n_lines = self.lib.QSPGetActionCode(i, lines, 100)

        if n_lines == 0 then
            is_active = false
        else
            local first_line = qspStringToUtf8(lines[0].Line)
            first_line = first_line:gsub("^%s+", ""):gsub("%s+$", "")
            if first_line == "ACT" or first_line:match("^ACT%s") or first_line:match("^ACT$") then
                is_active = false
            end
        end

        if is_active then
            self.actions[#self.actions + 1] = {
                name = name,
                index = i,
            }
        end
    end

    self.objects = {}
    local objs = ffi.new("QSPObjectItem[?]", 100)
    local n_objs = self.lib.QSPGetObjects(objs, 100)
    for i = 0, n_objs - 1 do
        local name = qspStringToUtf8(objs[i].Name)
        if name ~= "" then
            self.objects[#self.objects + 1] = {
                name = name,
                index = i,
            }
        end
    end
end

function QSPWidget:rebuild()
    -- Освобождаем старый HTML-виджет (защита от утечки памяти)
    if self.html_widget and self.html_widget.free then
        self.html_widget:free()
        self.html_widget = nil
    end

    -- Очищаем старый контейнер (освобождает дочерние виджеты)
    if self[1] then
        if self[1].clear then
            self[1]:clear()
        elseif self[1].free then
            self[1]:free()
        end
        self[1] = nil
    end

    self:updateState()
    self:buildLayout()
    UIManager:setDirty("all", "ui")
end

function QSPWidget:buildLayout()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    -- Минимальные отступы, чтобы текст занимал всю ширину
    local outer_margin = Size.margin.small

    -- === Заголовок: название + A- + A+ + ✕ (прижаты вправо) ===
    local title_text = TextWidget:new{
        text = self.file:match("([^/]+)$") or self.file,
        face = Font:getFace("cfont", 16),
        max_width = screen_w - 200,
    }

    local font_down_btn = Button:new{
        text = "A-",
        text_font_face = "cfont",
        text_font_size = 18,
        margin = Size.margin.tiny,
        callback = function()
            self:onFontSizeChange(-2)
        end,
    }

    local font_up_btn = Button:new{
        text = "A+",
        text_font_face = "cfont",
        text_font_size = 18,
        margin = Size.margin.tiny,
        callback = function()
            self:onFontSizeChange(2)
        end,
    }

    local close_btn = Button:new{
        text = "✕",
        text_font_face = "cfont",
        text_font_size = 20,
        margin = Size.margin.tiny,
        callback = function()
            self:onClose()
        end,
    }

    local title_bar = HorizontalGroup:new{
        align = "center",
        title_text,
        HorizontalSpan:new{ width = 10 },
        font_down_btn,
        HorizontalSpan:new{ width = 3 },
        font_up_btn,
        HorizontalSpan:new{ width = 3 },
        close_btn,
    }

    -- === HTML-текст игры (широкое поле) ===
    local dir = self.file:match("(.+)/[^/]+$") or "."
    local html_h = math.floor(screen_h * 0.5)

    self.html_widget = ScrollHtmlWidget:new{
        html_body = self.desc_html,
        default_font_size = self.font_size,
        html_resource_directory = dir,
        html_link_tapped_callback = function(link)
            self:onLinkTap(link)
        end,
        dialog = self,
        width = screen_w - 2 * outer_margin,
        height = html_h,
    }

    -- === Панель объектов ===
    local objects_hg = nil
    if #self.objects > 0 then
        local objs_children = {}
        for _, obj in ipairs(self.objects) do
            table.insert(objs_children, Button:new{
                text = obj.name:gsub("<[^>]+>", ""),
                text_font_face = "cfont",
                text_font_size = 16,
                margin = Size.margin.tiny,
                callback = function()
                    self:onObjectTap(obj.index)
                end,
            })
            table.insert(objs_children, HorizontalSpan:new{ width = 5 })
        end
        objects_hg = HorizontalGroup:new(objs_children)
    end

    -- === Кнопки действий (только активные) ===
    local actions_children = { align = "left" }
    for _, action in ipairs(self.actions) do
        table.insert(actions_children, Button:new{
            text = action.name,
            text_font_face = "cfont",
            text_font_size = 18,
            width = screen_w - 2 * outer_margin,
            margin = Size.margin.small,
            callback = function()
                self:onActionTap(action.index)
            end,
        })
    end
    local actions_group = VerticalGroup:new(actions_children)

    -- === Собираем контент ===
    local children = {
        align = "center",
        title_bar,
        VerticalSpan:new{ width = 10 },
        self.html_widget,
        VerticalSpan:new{ width = 10 },
    }
    if objects_hg then
        table.insert(children, objects_hg)
        table.insert(children, VerticalSpan:new{ width = 5 })
    end
    table.insert(children, actions_group)

    local vertical = VerticalGroup:new(children)

    -- === ScrollableContainer (почти во весь экран) ===
    local scrollable = ScrollableContainer:new{
        dimen = Geom:new{
            w = screen_w - 2 * outer_margin,
            h = screen_h - 2 * outer_margin,
        },
        vertical,
    }

    -- === FrameContainer (минимальные отступы) ===
    local frame = FrameContainer:new{
        margin = 0,
        padding = outer_margin,
        bordersize = 0,
        scrollable,
    }

    -- === Занимает весь экран ===
    local center = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
        frame,
    }

    self[1] = center
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
end

function QSPWidget:onFontSizeChange(delta)
    local new_size = self.font_size + delta
    if new_size < 12 then new_size = 12 end
    if new_size > 48 then new_size = 48 end
    if new_size == self.font_size then return true end

    self.font_size = new_size
    self:rebuild()
    return true
end

function QSPWidget:onLinkTap(link)
    local uri = link.uri
    if not uri then return end

    uri = uri:gsub("&gt;", ">"):gsub("&lt;", "<"):gsub("&amp;", "&"):gsub("&quot;", '"')

    local qsp_cmd = uri:match("^EXEC:(.*)$") or uri
    local cmd = makeQSPString(qsp_cmd)
    local ok = self.lib.QSPExecString(cmd, 1)
    if not ok then
        logger.warn("QSP: QSPExecString failed for:", qsp_cmd)
    end

    self:rebuild()
end

function QSPWidget:onActionTap(index)
    if not self.loaded then return true end

    self.lib.QSPSetSelActionIndex(index, 1)
    self.lib.QSPExecuteSelActionCode(1)

    self:rebuild()
    return true
end

function QSPWidget:onObjectTap(index)
    if not self.loaded then return true end

    self.lib.QSPSetSelObjectIndex(index, 1)

    self:rebuild()
    return true
end

-- Поглощаем свайпы, чтобы UIManager не закрыл виджет
function QSPWidget:onSwipeIgnore(arg, ges)
    return true
end

function QSPWidget:onClose()
    UIManager:close(self)
    return true
end

function QSPWidget:onCloseWidget()
    if self.lib and self.loaded then
        self.lib.QSPTerminate()
        self.loaded = false
    end

    if self.html_widget and self.html_widget.free then
        self.html_widget:free()
        self.html_widget = nil
    end
end

return QSPWidget