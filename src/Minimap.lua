local _, BDR = ...

-- Minimap button — a tiny skull on the minimap edge. Left-click toggles the recap
-- window (the same as /bdr); right-click opens the options panel. Draggable around
-- the ring (angle persisted in DB). Hand-rolled (no LibDBIcon) to stay
-- dependency-free, per CLAUDE.md.

local Minimap_ = {}
BDR.Minimap = Minimap_

local ICON = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01"  -- a skull (death theme)

local button

-- Per-quadrant "is this corner rounded?" by minimap shape. Addons that make the
-- minimap square/rectangular define a global `GetMinimapShape()` returning one of
-- these keys; default is ROUND. (Same table LibDBIcon uses.)
local minimapShapes = {
    ["ROUND"]                 = { true,  true,  true,  true  },
    ["SQUARE"]                = { false, false, false, false },
    ["CORNER-TOPLEFT"]        = { false, false, false, true  },
    ["CORNER-TOPRIGHT"]       = { false, false, true,  false },
    ["CORNER-BOTTOMLEFT"]     = { false, true,  false, false },
    ["CORNER-BOTTOMRIGHT"]    = { true,  false, false, false },
    ["SIDE-LEFT"]             = { false, true,  false, true  },
    ["SIDE-RIGHT"]            = { true,  false, true,  false },
    ["SIDE-TOP"]              = { false, false, true,  true  },
    ["SIDE-BOTTOM"]           = { true,  true,  false, false },
    ["TRICORNER-TOPLEFT"]     = { false, true,  true,  true  },
    ["TRICORNER-TOPRIGHT"]    = { true,  false, true,  true  },
    ["TRICORNER-BOTTOMLEFT"]  = { true,  true,  false, true  },
    ["TRICORNER-BOTTOMRIGHT"] = { true,  true,  true,  false },
}

-- Place the button on the minimap edge at the stored angle — on the circle for
-- round minimaps, clamped to the rectangle for square/rectangular ones.
local function UpdatePosition()
    if not button then return end
    local angle = math.rad(BDR.DB.minimapAngle or 200)
    local x, y, q = math.cos(angle), math.sin(angle), 1
    if x < 0 then q = q + 1 end
    if y > 0 then q = q + 2 end

    local shape = (GetMinimapShape and GetMinimapShape()) or "ROUND"
    local quad  = minimapShapes[shape] or minimapShapes.ROUND
    local w = (Minimap:GetWidth()  / 2) + 5
    local h = (Minimap:GetHeight() / 2) + 5
    if quad[q] then
        x, y = x * w, y * h                         -- rounded quadrant: on the ellipse
    else
        x = math.max(-w, math.min(x * math.sqrt(2 * w * w) - 10, w))   -- square: clamp to the edge
        y = math.max(-h, math.min(y * math.sqrt(2 * h * h) - 10, h))
    end
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- While dragging, follow the cursor around the ring and persist the new angle.
local function DragUpdate()
    local mx, my = Minimap:GetCenter()
    local scale  = Minimap:GetEffectiveScale()
    local px, py = GetCursorPosition()
    if not (mx and px and scale and scale > 0) then return end
    px, py = px / scale, py / scale
    BDR.DB.minimapAngle = math.deg(math.atan2(py - my, px - mx))
    UpdatePosition()
end

local function ShowTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("|cffff5555Better|r|cfff0e6d2DeathRecap|r")
    GameTooltip:AddLine(BDR.L.MINIMAP_LEFT, 0.9, 0.9, 0.9)
    GameTooltip:AddLine(BDR.L.MINIMAP_RIGHT, 0.9, 0.9, 0.9)
    GameTooltip:Show()
end

function Minimap_:Init()
    if button then self:SetShown(BDR.DB.minimapShown ~= false); return end

    button = CreateFrame("Button", "BetterDeathRecapMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetClampedToScreen(true)

    -- The tracking border (53px at the button's TOPLEFT) frames a 20px disc anchored
    -- at TOPLEFT (7,-5) — anchoring the icon there centres it inside the ring. Round
    -- it with SetMask (simpler/more reliable than CreateMaskTexture).
    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetTexture(ICON)
    icon:SetPoint("TOPLEFT", button, "TOPLEFT", 7, -5)
    icon:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    -- The button's own highlight (correctly sized/blended) — NOT a manual HIGHLIGHT
    -- texture, which rendered as a stray blue square on hover.
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    button:SetScript("OnClick", function(_, mouse)
        if mouse == "RightButton" then
            if BDR.Options then BDR.Options:Open() end
        else
            BDR.Display:Toggle()   -- same as /bdr
        end
    end)
    button:SetScript("OnDragStart", function() button:SetScript("OnUpdate", DragUpdate) end)
    button:SetScript("OnDragStop",  function() button:SetScript("OnUpdate", nil) end)
    button:SetScript("OnEnter", ShowTooltip)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    UpdatePosition()
    self:SetShown(BDR.DB.minimapShown ~= false)
end

function Minimap_:SetShown(shown)
    if not button then return end
    if shown then button:Show() else button:Hide() end
end

-- Re-place the button. Called after all addons load (PLAYER_ENTERING_WORLD) so a
-- square/rectangular minimap from another addon is honoured — at our ADDON_LOADED,
-- that addon may not have defined GetMinimapShape() yet (it can load after us).
function Minimap_:Reposition()
    UpdatePosition()
end
