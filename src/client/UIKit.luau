--!strict
-- Small helpers for building UI in code (used by the lobby and deck builder).

local UIKit = {}

UIKit.BG = Color3.fromRGB(22, 24, 30)
UIKit.PANEL = Color3.fromRGB(34, 37, 46)
UIKit.TEXT = Color3.fromRGB(235, 235, 240)
UIKit.MUTED = Color3.fromRGB(150, 155, 170)
UIKit.GOOD = Color3.fromRGB(60, 120, 70)
UIKit.BAD = Color3.fromRGB(150, 50, 50)
UIKit.BUTTON = Color3.fromRGB(64, 70, 88)
UIKit.FONT = Enum.Font.GothamMedium
UIKit.COLORS = {
	Red = Color3.fromRGB(176, 52, 52),
	Blue = Color3.fromRGB(48, 96, 190),
	Yellow = Color3.fromRGB(190, 160, 30),
	Green = Color3.fromRGB(46, 140, 70),
	Purple = Color3.fromRGB(120, 66, 170),
}

local order = 0

function UIKit.new(className: string, props: { [string]: any }, children: { Instance }?): any
	local inst = Instance.new(className)
	if inst:IsA("GuiObject") then
		order += 1
		inst.LayoutOrder = order
	end
	for k, v in props do
		if k ~= "Parent" then
			(inst :: any)[k] = v
		end
	end
	for _, c in children or {} do
		c.Parent = inst
	end
	if props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end

function UIKit.label(parent: Instance, text: string, props: { [string]: any }?): TextLabel
	local p: { [string]: any } = {
		BackgroundTransparency = 1,
		Text = text,
		TextColor3 = UIKit.TEXT,
		Font = UIKit.FONT,
		TextSize = 14,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 20),
		Parent = parent,
	}
	for k, v in props or {} do
		p[k] = v
	end
	return UIKit.new("TextLabel", p)
end

function UIKit.button(parent: Instance, text: string, onClick: () -> (), props: { [string]: any }?): TextButton
	local p: { [string]: any } = {
		Name = "Btn_" .. text:gsub("[^%w]", ""),
		BackgroundColor3 = UIKit.BUTTON,
		Text = text,
		TextColor3 = UIKit.TEXT,
		Font = UIKit.FONT,
		TextSize = 14,
		AutoButtonColor = true,
		Size = UDim2.new(0, 120, 0, 30),
		Parent = parent,
	}
	for k, v in props or {} do
		p[k] = v
	end
	local b = UIKit.new("TextButton", p)
	UIKit.new("UICorner", { CornerRadius = UDim.new(0, 6), Parent = b })
	b.MouseButton1Click:Connect(onClick)
	return b
end

function UIKit.list(parent: Instance, horizontal: boolean?, padding: number?)
	return UIKit.new("UIListLayout", {
		FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical,
		Padding = UDim.new(0, padding or 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = if horizontal then Enum.VerticalAlignment.Center else Enum.VerticalAlignment.Top,
		Parent = parent,
	})
end

function UIKit.pad(parent: Instance, px: number)
	UIKit.new("UIPadding", {
		PaddingLeft = UDim.new(0, px),
		PaddingRight = UDim.new(0, px),
		PaddingTop = UDim.new(0, px),
		PaddingBottom = UDim.new(0, px),
		Parent = parent,
	})
end

function UIKit.panel(parent: Instance, props: { [string]: any }): Frame
	local p: { [string]: any } = { BackgroundColor3 = UIKit.PANEL, Parent = parent }
	for k, v in props do
		p[k] = v
	end
	local f = UIKit.new("Frame", p)
	UIKit.new("UICorner", { CornerRadius = UDim.new(0, 8), Parent = f })
	return f
end

-- Removes content and layouts, keeps padding and corners.
function UIKit.clear(inst: Instance)
	for _, c in inst:GetChildren() do
		if not (c:IsA("UIPadding") or c:IsA("UICorner")) then
			c:Destroy()
		end
	end
end

return UIKit
