-- === CONFIGURATION ===
local socket = require("socket")
local tcp = nil
local AI_HOST = "127.0.0.1"
local AI_PORT = 5005
local TIME_STEP = 1.0/60.0 
local FRAME_SKIP = 4 

local METER = 30 
local GRAVITY = 9.81 * METER
local BLOCK_SIZE = 30
local SNAP_SIZE = 15 
local PLATFORM_WIDTH = 160 
local PLATFORM_Y = 550
local RAY_COUNT = 20 
local WINDOW_WIDTH = 800
local WINDOW_HEIGHT = 600

-- THRESHOLDS
local GAME_OVER_Y = PLATFORM_Y + 100 
local CLEANUP_Y = PLATFORM_Y + 450
local STABILITY_THRESHOLD = 5.0 -- Stricter stability check

local appState = "menu" 
local gameMode = "human" 
local renderEnabled = true 
local globalRecordMeters = 0

local world, ground
local objects = {} 
local currentPiece = nil 
local nextPieceKey = nil 
local gameState = "playing"
local cameraY = 0

local targetGridX = 400
local targetRotation = 0
local spawnTimer = 0
local towerVelocity = 0 

local pendingAIAction = 4 
local currentReward = 0
local previousMaxHeight = PLATFORM_Y
local recordHighY = PLATFORM_Y 
local deathReason = "Unknown" -- For logging

local shapes = {
    I = { {-1.5, -0.5}, {-0.5, -0.5}, {0.5, -0.5}, {1.5, -0.5}, color={0.3, 0.8, 0.9} },
    O = { {-0.5, -0.5}, {0.5, -0.5}, {-0.5, 0.5}, {0.5, 0.5}, color={0.9, 0.9, 0.2} },
    T = { {-0.5, -0.5}, {0.5, -0.5}, {-0.5, 0.5}, {1.5, -0.5}, color={0.8, 0.2, 0.8} },
    S = { {-0.5, 0.5}, {0.5, 0.5}, {0.5, -0.5}, {1.5, -0.5}, color={0.2, 0.9, 0.2} },
    Z = { {-0.5, -0.5}, {0.5, -0.5}, {0.5, 0.5}, {1.5, 0.5}, color={0.9, 0.2, 0.2} },
    J = { {-0.5, -0.5}, {-0.5, 0.5}, {0.5, 0.5}, {1.5, 0.5}, color={0.2, 0.2, 0.9} },
    L = { {1.5, -0.5}, {1.5, 0.5}, {0.5, 0.5}, {-0.5, 0.5}, color={0.9, 0.5, 0.2} }
}
local shapeKeys = {"I", "O", "T", "S", "Z", "J", "L"}
local shapeMap = {I=1, O=2, T=3, S=4, Z=5, J=6, L=7}

function love.load()
    love.window.setTitle("Tricky Towers - Stability Update")
    love.window.setMode(WINDOW_WIDTH, WINDOW_HEIGHT)
    math.randomseed(os.time())
end

function love.keypressed(key)
    if appState == "menu" then
        if key == "1" then startHumanMode()
        elseif key == "2" then startAIMode() end
        return
    end
    if gameMode == "ai" and key == "v" then renderEnabled = not renderEnabled end
    if key == "escape" then love.event.quit() end
    if gameState == "gameover" and key == "r" then restartGame() end
    
    -- Human Controls
    if gameMode == "human" and currentPiece and not currentPiece.landed then
        if key == "up" then targetRotation = targetRotation + (math.pi/2) end
    end
end

function startHumanMode() gameMode = "human"; appState = "game"; renderEnabled = true; love.window.setVSync(1); initGame() end
function startAIMode()
    gameMode = "ai"; appState = "game"; renderEnabled = false; love.window.setVSync(0)
    tcp = socket.tcp(); tcp:setoption("tcp-nodelay", true)
    local s, e = tcp:connect(AI_HOST, AI_PORT)
    if not s then appState = "menu" else tcp:settimeout(0); initGame() end
end

function love.update(dt)
    if appState == "menu" then return end
    if gameMode == "human" then updateHuman(dt) else updateAI(dt) end
    updateCamera(dt)
end

function updateHuman(dt)
    if gameState == "gameover" then return end
    world:update(dt)
    if not currentPiece then
        spawnTimer = spawnTimer - dt
        if spawnTimer <= 0 then spawnPiece() end
    else
        if not currentPiece.landed then
            handleHumanInput(dt)
            local vy = love.keyboard.isDown("down") and 600 or 150
            currentPiece.body:setX(targetGridX); currentPiece.body:setAngle(targetRotation)
            currentPiece.body:setLinearVelocity(0, vy); currentPiece.body:setAngularVelocity(0)
            if currentPiece.body:getY() > GAME_OVER_Y then currentPiece.body:destroy(); currentPiece = nil; spawnPiece() end
        end
    end
    checkTowerCollapse(); cleanupFallenBlocks()
end

function updateAI(dt)
    if not tcp then return end
    
    -- Calc Wobble
    towerVelocity = 0
    for _, obj in ipairs(objects) do
        if not obj.body:isDestroyed() then
            local vx, vy = obj.body:getLinearVelocity()
            towerVelocity = towerVelocity + math.abs(vx) + math.abs(vy)
        end
    end

    for i=1, FRAME_SKIP do
        world:update(TIME_STEP)
        if gameState == "playing" then currentReward = currentReward + 0.05 end
        
        if currentPiece and not currentPiece.landed then
            currentPiece.body:setX(targetGridX); currentPiece.body:setAngle(targetRotation)
            local vy = (pendingAIAction == 3) and 1000 or 150
            currentPiece.body:setLinearVelocity(0, vy); currentPiece.body:setAngularVelocity(0)
            
            -- DEATH: Piece fell off platform
            if currentPiece.body:getY() > GAME_OVER_Y then 
                gameState = "gameover"
                deathReason = "Dropped Off Edge"
                currentReward = currentReward - 100 -- HUGE PENALTY
            end
        end
        checkTowerCollapse(); cleanupFallenBlocks()
        if gameState == "gameover" then break end
    end
    
    local line, err = tcp:receive("*l")
    if err == "closed" then love.event.quit() return end
    if line == "RESET" then restartGame(); sendState(0, false); return end
    if line then pendingAIAction = tonumber(line); performAIAction(pendingAIAction) end
    
    calculateAIRewards()
    local done = (gameState == "gameover")
    if line or done then sendState(currentReward, done); currentReward = 0 end
    
    -- STABILITY GATE
    if not currentPiece then 
        if spawnTimer > 0 then spawnTimer = spawnTimer - dt * FRAME_SKIP
        elseif towerVelocity < STABILITY_THRESHOLD then spawnPiece()
        else currentReward = currentReward + 0.1 end -- Patience reward
    end
end

function initGame()
    if world then world:destroy() end
    world = love.physics.newWorld(0, GRAVITY, true); world:setCallbacks(beginContact, nil, nil, nil)
    ground = {}; ground.body = love.physics.newBody(world, 400, PLATFORM_Y, "static")
    ground.shape = love.physics.newRectangleShape(PLATFORM_WIDTH, 40); ground.fixture = love.physics.newFixture(ground.body, ground.shape); ground.fixture:setFriction(1.0)
    objects = {}; currentPiece = nil; nextPieceKey = shapeKeys[love.math.random(#shapeKeys)]
    gameState = "playing"; cameraY = 0; spawnTimer = 0
    currentReward = 0; previousMaxHeight = PLATFORM_Y; recordHighY = PLATFORM_Y; towerVelocity = 0; 
    pendingAIAction = 4 -- SAFETY RESET: Ensure AI doesn't start with "Drop" held down
    deathReason = ""
    spawnPiece()
end

function restartGame() initGame() end

function spawnPiece()
    local key = nextPieceKey; nextPieceKey = shapeKeys[love.math.random(#shapeKeys)]
    local shapeDef = shapes[key]
    local highestY = PLATFORM_Y
    for _, obj in ipairs(objects) do
        if obj.body and not obj.body:isDestroyed() and obj.body:getY() < highestY then highestY = obj.body:getY() end
    end
    local body = love.physics.newBody(world, 405, highestY - 350, "dynamic")
    body:setGravityScale(0); body:setFixedRotation(true); body:setBullet(true)
    for _, c in ipairs(shapeDef) do
        local s = love.physics.newRectangleShape(c[1]*30, c[2]*30, 28, 28, 0)
        local f = love.physics.newFixture(body, s, 1); f:setFriction(0.6); f:setRestitution(0.0)
    end
    currentPiece = { body = body, color = shapeDef.color, landed = false, type = key }
    targetGridX = 405; targetRotation = 0
end

function beginContact(a, b, coll)
    if not currentPiece then return end
    local isPiece = false
    for _, f in ipairs(currentPiece.body:getFixtures()) do if a == f or b == f then isPiece = true break end end
    if isPiece and not currentPiece.landed then
        currentPiece.landed = true
        currentPiece.body:setGravityScale(1); currentPiece.body:setFixedRotation(false); currentPiece.body:setBullet(false)
        local vx, vy = currentPiece.body:getLinearVelocity()
        currentPiece.body:setLinearVelocity(vx*0.1, vy*0.1)
        currentPiece.body:setAngularDamping(2.0); currentPiece.body:setLinearDamping(0.5)
        
        if gameMode == "ai" then 
            currentReward = currentReward + 2.0 
            -- Center Bias
            local dist = math.abs(currentPiece.body:getX() - 400)
            if dist > 40 then currentReward = currentReward - (dist * 0.05) end
        end
        
        table.insert(objects, currentPiece); currentPiece = nil; spawnTimer = 0.2 
    end
end

function performAIAction(act)
    if not currentPiece then return end
    if act == 0 then targetGridX = targetGridX - SNAP_SIZE
    elseif act == 1 then targetGridX = targetGridX + SNAP_SIZE
    elseif act == 2 then targetRotation = targetRotation + (math.pi/2) end
end

function handleHumanInput(dt)
    local function p(t, k, d)
        if love.keyboard.isDown(k) then
            if t == 0 then targetGridX = targetGridX + d*SNAP_SIZE; return 0.25
            elseif t > 0 then t = t - dt; if t < 0 then t = -0.08 end; return t
            else t = t + dt; if t >= 0 then targetGridX = targetGridX + d*SNAP_SIZE; return -0.08 end; return t end
        else return 0 end
    end
    leftTimer = p(leftTimer, "left", -1); rightTimer = p(rightTimer, "right", 1)
end

function calculateAIRewards()
    local currentMaxY = PLATFORM_Y
    local minX, maxX = 400, 400 -- Track width
    
    for _, obj in ipairs(objects) do
        if not obj.body:isDestroyed() then
            local x, y = obj.body:getPosition()
            if y < currentMaxY then currentMaxY = y end
            if x < minX then minX = x end
            if x > maxX then maxX = x end
        end
    end
    if currentMaxY < recordHighY then recordHighY = currentMaxY end
    local currentH = math.floor((PLATFORM_Y - recordHighY)/METER)
    if currentH > globalRecordMeters then globalRecordMeters = currentH end

    local gain = (previousMaxHeight - currentMaxY) / METER
    if gain > 0 then 
        -- WIDTH MULTIPLIER (Anti-Needle)
        -- 30px = 1 block wide. 90px = 3 blocks wide.
        local width = (maxX - minX)
        local multiplier = 0.5 -- Penalty for being thin
        if width > 70 then multiplier = 1.2 end -- Bonus for being >2 blocks wide
        if width > 110 then multiplier = 1.5 end -- Big Bonus for being wide
        
        currentReward = currentReward + (gain * 10.0 * multiplier)
        previousMaxHeight = currentMaxY 
    end
end

function checkTowerCollapse()
    local currentTopY = PLATFORM_Y; local hasBlocks = false
    for i, obj in ipairs(objects) do
        if not obj.body:isDestroyed() then
            local oy = obj.body:getY()
            if oy > GAME_OVER_Y then
                if gameMode == "ai" then 
                    gameState = "gameover"; 
                    deathReason = "Block Fell"
                    currentReward = currentReward - 100; return
                else obj.body:destroy(); table.remove(objects, i); goto continue end
            end
            if oy < currentTopY then currentTopY = oy; hasBlocks = true end
            ::continue::
        end
    end
    if hasBlocks and (currentTopY > recordHighY + 300) and gameMode == "ai" then 
        gameState = "gameover"; 
        deathReason = "Tower Collapsed"
        currentReward = currentReward - 100 
    end
end

function cleanupFallenBlocks()
    for i, obj in ipairs(objects) do
        if not obj.body:isDestroyed() and obj.body:getY() > CLEANUP_Y then obj.body:destroy(); table.remove(objects, i) end
    end
end

function updateCamera(dt)
    local highestY = PLATFORM_Y - 20
    for _, obj in ipairs(objects) do
        if obj.body and not obj.body:isDestroyed() and obj.body:getY() < highestY then highestY = obj.body:getY() end
    end
    local screenTarget = highestY - 350; if screenTarget > 0 then screenTarget = 0 end
    targetCameraY = -screenTarget; cameraY = cameraY + (targetCameraY - cameraY) * 2.0 * dt
end

function sendState(reward, done)
    local inputs = {}
    local startX, endX = 300, 500; local step = (endX - startX) / (RAY_COUNT - 1)
    for i = 0, RAY_COUNT-1 do
        local rayX = startX + (i * step); local hitY = PLATFORM_Y
        local function cb(f, x, y, xn, yn, fr) if currentPiece and f:getBody() == currentPiece.body then return -1 end; hitY = y; return fr end
        world:rayCast(rayX, -2000, rayX, PLATFORM_Y + 50, cb)
        table.insert(inputs, hitY / (PLATFORM_Y + 50))
    end
    if currentPiece then
        table.insert(inputs, (currentPiece.body:getX() - 300) / 200)
        table.insert(inputs, (currentPiece.body:getAngle() % (math.pi*2)) / (math.pi*2))
        table.insert(inputs, shapeMap[currentPiece.type] / 7.0)
    else table.insert(inputs, 0); table.insert(inputs, 0); table.insert(inputs, 0) end
    table.insert(inputs, shapeMap[nextPieceKey] / 7.0)
    table.insert(inputs, math.min(towerVelocity / 500.0, 1.0))
    
    -- SEND DEATH REASON AT END OF PACKET
    local rInfo = (done and deathReason ~= "") and deathReason or "Alive"
    tcp:send(table.concat(inputs, ",") .. "|" .. reward .. "|" .. (done and 1 or 0) .. "|" .. rInfo .. "\n")
end

function love.draw()
    if appState == "menu" then drawMenu() return end
    love.graphics.setColor(0,1,0); love.graphics.setFont(love.graphics.newFont(14)); love.graphics.print("FPS: "..love.timer.getFPS(),10,10)
    love.graphics.setColor(1, 0.5, 0); love.graphics.print("BEST: " .. globalRecordMeters .. "m", 10, 150)
    if gameMode == "ai" and not renderEnabled then
        love.graphics.setColor(1,1,1); love.graphics.print("AI TRAINING (FAST) - Press V", 10, 30)
        love.graphics.print("Current: "..math.floor((PLATFORM_Y - recordHighY)/METER).."m", 10, 50); 
        love.graphics.setColor(1,0,0); love.graphics.print("Status: " .. (gameState=="gameover" and deathReason or "Stable"), 10, 80)
        return
    end
    love.graphics.push(); love.graphics.translate(0, cameraY)
    local off = math.floor(cameraY)
    love.graphics.setColor(1,1,1,0.05); for x=0,WINDOW_WIDTH,SNAP_SIZE do love.graphics.line(x,-off-100,x,-off+WINDOW_HEIGHT) end
    love.graphics.setColor(0.5,0.5,0.6); love.graphics.polygon("fill", ground.body:getWorldPoints(ground.shape:getPoints()))
    for _, o in ipairs(objects) do drawBlock(o) end
    if currentPiece then drawBlock(currentPiece) end
    love.graphics.pop()
    if gameMode == "ai" then love.graphics.setColor(1,1,0); love.graphics.print("Visual ON (V to Hide)", 10, 30) end
end
function drawMenu() love.graphics.clear(0.1,0.1,0.1); love.graphics.printf("TRICKY TOWERS AI\n1. Human\n2. AI Training", 0, 200, WINDOW_WIDTH, "center") end
function drawBlock(o) if not o or not o.body then return end; love.graphics.setColor(o.color); for _,f in ipairs(o.body:getFixtures()) do local p={o.body:getWorldPoints(f:getShape():getPoints())}; love.graphics.polygon("fill",p); love.graphics.setColor(0,0,0,0.5); love.graphics.polygon("line",p); love.graphics.setColor(o.color) end end