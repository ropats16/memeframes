--[[
  MEMEFRAMES Version: 0.3

  This Lua script is part of a system designed for creating and managing a community-driven meme frame display, 
  leveraging Arweave's blockchain for decentralized storage. Users can mint tokens, stake them to participate in voting, 
  and submit their votes for their favorite memes to be displayed.

  Dependencies:
  - Token blueprint: Handles token-related actions such as minting and transferring.
  - Staking blueprint: Manages staking actions, necessary for enabling voting rights.

  Installation Instructions:
  1. Load the token and staking blueprints with the following commands:
     > .load-blueprint token
     > .load-blueprint staking
  2. Load this script to initialize the MEMEFRAMES process:
     > .load process/memeframes.lua

  Features:
  - Get-Info: Displays a manual page for user interaction.
  - Get-Votes: Returns the current voting results.
]]

-- Required Lua modules and initial setup.
local json = require('json')
Votes = Votes or {} -- Initialize Votes if not already set.

-- Configuration for purchasing and minting tokens.
BuyToken = "GwYlfSvxTuf85y3aF88wMvv9ZmcKuaINmXxSiMh_-l0"
MaxMint = 1000000 -- Maximum amount of tokens that can be minted.
Minted = Minted or 0 -- Tracks the amount of tokens already minted.

-- Default frame ID and meme name initialization.
FrameID = FrameID or Inbox[1].FrameID 
MEMEFRAME_NAME = MEMEFRAME_NAME or Inbox[1]["MemeFrame-Name"]

-- Configuration for voting: the block height limit for a vote's duration.
VoteLength = 1 -- Set to 1 for demonstration, adjust based on your block time for longer votes.

-- Generates a manual page with instructions for interaction.
function Man(name) 
  return string.format([[
  # Arweave India MEME: %s

  Join the Arweave India MemeFrame community. Mint MemeFrame Tokens using $CREDSPOOF, then stake them for voting on the webpage to display
  on the community's MemeFrame page.

  ## How to Interact

  - Mint tokens to get started.
  - Stake tokens to gain voting rights.
  - Vote for your favorite memes to be displayed.
  - Retrieve current vote standings.

  ## Mint

  ```
  Send({Target = CREDSPOOF, Action = "Transfer", Quantity = "1000", Recipient = MEMEFRAME  })
  ```

  ## Stake

  ```
  Send({Target = MEMEFRAME, Action = "Stake", Quantity = "1000", UnstakeDelay = "1000"})
  ```

  ## Vote

  ```
  Send({Target = MEMEFRAME, Action = "Vote", Side = "yay", VoteID = "{TXID}" })
  ```

  ## Get-Votes

  ```
  Send({Target = MEMEFRAME, Action = "Get-Votes"})
  ```


]], name, ao.id)
end

-- Broadcasts a message to a list of participant IDs.
local function announce(msg, pids)
Utils.map(function (pid) 
  Send({Target = pid, Data = msg })
end, pids)
end

-- Handler to retrieve and send current vote standings.
Handlers.prepend("Get-Votes", function (m) 
return m.Action == "Get-Votes"
end, function (m)
Send({
  Target = m.From,
  Data = require('json').encode(
      Utils.map(function (k) return { tx = k, yay = Votes[k].yay, nay = Votes[k].nay, deadline = Votes[k].deadline} end ,
       Utils.keys(Votes))
    )  
}) 
print("Sent Votes to caller")
end)

-- Provides information about how to interact with the MemeFrame system.
Handlers.prepend("Get-Info", function (m) return m.Action == "Get-Info" end, function (m)
Send({
  Target = m.From,
  Data = Man(MEMEFRAME_NAME)
})
print('Sent Info to ' .. m.From)
end)

-- Handles the minting process for tokens upon receiving a credit notice.
Handlers.prepend(
"Mint",
function(m)
  return m.Action == "Credit-Notice" and m.From == BuyToken
end,
function(m)
  local requestedAmount = tonumber(m.Quantity)
  local actualAmount = requestedAmount
  -- Checks if the mint request exceeds the max mint limit.
    -- if over limit refund difference
    if (Minted + requestedAmount) > MaxMint then
      -- if not enough tokens available send a refund...
        Send({
          Target = BuyToken,
          Action = "Transfer",
          Recipient = m.Sender,
          Quantity = tostring(requestedAmount),
          Data = "Meme is Maxed - Refund"
        })
        print('send refund')
      Send({Target = m.Sender, Data = "Meme Maxed Refund dispatched"})
      return
    end
    assert(type(Balances) == "table", "Balances not found!")
    local prevBalance = tonumber(Balances[m.Sender]) or 0
    Balances[m.Sender] = tostring(math.floor(prevBalance + actualAmount))
    Minted = Minted + actualAmount
    print("Minted " .. tostring(actualAmount) .. " to " .. m.Sender)
    Send({Target = m.Sender, Data = "Successfully Minted " .. actualAmount})
  end
)

-- GET-FRAME Handler: Sends the current Frame ID to the requester.
-- This function allows users to query the current frame being displayed or voted on.
Handlers.prepend(
  "Get-Frame",
  Handlers.utils.hasMatchingTag("Action", "Get-Frame"),
  function(m)
    Send({
      Target = m.From,
      Action = "Frame-Response",
      Data = FrameID
    })
    print("Sent FrameID: " .. FrameID)
  end
)

-- Utility function to allow message processing to continue under certain conditions.
-- This function is used to chain handlers and manage the flow of actions.
local function continue(fn) 
  return function (msg) 
    local result = fn(msg)
    if result == -1 then 
      return "continue"
    end
    return result
  end
end

-- Vote Handler: Manages the voting process, allowing users to vote on proposals.
-- Validates if the user is a staker and has enough staked tokens to vote. Updates the vote count for each proposal.
Handlers.prepend("vote", 
  continue(Handlers.utils.hasMatchingTag("Action", "Vote")),
  function (m)
    assert(type(Stakers) == "table", "Stakers is not in process, please load blueprint")
    assert(type(Stakers[m.From]) == "table", "Is not staker")
    assert(m.Side and (m.Side == 'yay' or m.Side == 'nay'), 'Vote yay or nay is required!')

    local quantity = tonumber(Stakers[m.From].amount)
    local id = m.VoteID
    local command = m.Command or ""
    
    assert(quantity > 0, "No Staked Tokens to vote")
    if not Votes[id] then
      local deadline = tonumber(m['Block-Height']) + VoteLength
      Votes[id] = { yay = 0, nay = 0, deadline = deadline, command = command, voted = { } }
    end
    if Votes[id].deadline > tonumber(m['Block-Height']) then
      if Utils.includes(m.From, Votes[id].voted) then
        Send({Target = m.From, Data = "Already-Voted"})
        return
      end
      Votes[id][m.Side] = Votes[id][m.Side] + quantity
      table.insert(Votes[id].voted, m.From)
      print("Voted " .. m.Side .. " for " .. id)
      Send({Target = m.From, Data = "Voted"})
    else 
      Send({Target = m.From, Data = "Expired"})
    end
  end
)

-- Finalization Handler: Processes the outcome of votes after the deadline.
-- This handler checks the voting results for each proposal and updates the frame or executes commands based on the votes.
Handlers.after("vote").add("VoteFinalize",
function (msg) 
  return "continue"
end,
function(msg)
  local currentHeight = tonumber(msg['Block-Height'])
  
  -- Process voting
  for id, voteInfo in pairs(Votes) do
      print("Processing Vote: " .. id)
      if currentHeight >= voteInfo.deadline then
        print("Vote deadline passed..")
          if voteInfo.yay > voteInfo.nay then
            print("More yays received..")
              if voteInfo.command == "" then
                -- Updates the Frame ID to the winning proposal.
                FrameID = id
              else
                -- TODO: Test that command execution runs with the right scope?
                local func, err = load(voteInfo.command, Name, 't', _G)
                if not err then
                  func()
                else 
                  error(err)
                end
              end
          end
          -- Announces the vote's completion.
          announce(string.format("Vote %s Complete", id), Utils.keys(Stakers))
          -- Clear the vote record after processing
          -- Votes[id] = nil
      end
  end
end
)