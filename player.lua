-- inspiration from https://www.asciimation.co.nz/
-- SW file from: https://raw.githubusercontent.com/nitram509/ascii-telnet-server/master/sample_movies/sw1.txt

--[[
	TODO:
		- make the movie loop
		- support for the other movies based the maximum line length
]]--

local component = require("component")

local CHARS_PER_LINE = 67
local LINES_PER_FRAME = 14
local DELAY_NORMAL = 67

function play()
	frame = { }
	frameCounter = 0
	
	local previousFrameDuration = 1
	
	for line in io.lines("sw1.txt") do
		table.insert(frame, line)
		
		if #frame == LINES_PER_FRAME then
			os.sleep( (DELAY_NORMAL * previousFrameDuration) / 1000) -- hold the frame on screen

			frameCounter = frameCounter + 1
						
			previousFrameDuration = tonumber(frame[1])
			
			--os.execute("clear")
			for i, text in ipairs(frame) do
				print(text)
			end
			
			frame = { }
		end		
				
	end
	
end

local gpu = component.gpu -- get primary gpu component
local w, h = gpu.getResolution()

gpu.setResolution(CHARS_PER_LINE, LINES_PER_FRAME)

play()

-- set back to normal res
gpu.setResolution(w, h)

