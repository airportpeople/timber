-- Timber Player
--
-- Grid or MIDI keys
-- play samples.
--
-- E1 : Page
-- K1+E1 : Sample slot
-- K1 (Hold) : Shift / Fine
--
-- GLOBAL PAGE:
--  K2 : Load folder
--  K1+K2 : Add folder
--  K3 : Play / Stop
--  E3 : BPM
--
-- SAMPLE PAGES:
--  K2 : Focus
--  K3 : Action
--  E2/3 : Params
--
-- v1.0.0 Mark Eats
--

function unrequire(name)
  package.loaded[name] = nil
  _G[name] = nil
end
unrequire("timber/lib/timber_engine")

local Timber = require "timber/lib/timber_engine"
local MusicUtil = require "musicutil"
local UI = require "ui"
local Formatters = require "formatters"
local BeatClock = require "beatclock"

engine.name = "Timber"

local options = {}
options.OFF_ON = {"Off", "On"}
options.QUANTIZATION = {"None", "1/32", "1/24", "1/16", "1/12", "1/8", "1/6", "1/4", "1/3", "1/2", "1 bar"}
options.QUANTIZATION_DIVIDERS = {nil, 32, 24, 16, 12, 8, 6, 4, 3, 2, 1}

local SCREEN_FRAMERATE = 15
local screen_dirty = true
local GRID_FRAMERATE = 30
local grid_dirty = true
local grid_w, grid_h = 16, 8

local midi_in_device
local midi_clock_in_device
local midi_clock_out_device
local grid_device

local NUM_SAMPLES = 256

local beat_clock
local note_queue = {}

local sample_status = {}
local STATUS = {
  STOPPED = 0,
  STARTING = 1,
  PLAYING = 2,
  STOPPING = 3
}
for i = 0, NUM_SAMPLES - 1 do sample_status[i] = STATUS.STOPPED end

local pages
local global_view
local sample_setup_view
local waveform_view
local filter_amp_view
local amp_env_view
local mod_env_view
local lfos_view
local mod_matrix_view

local current_sample_id = 0
local shift_mode = false
local file_select_active = false


local function load_folder(file, add)
  
  local sample_id = 0
  if add then
    for i = NUM_SAMPLES - 1, 0, -1 do
      if Timber.samples_meta[i].num_frames > 0 then
        sample_id = i + 1
        break
      end
    end
  end
  
  Timber.clear_samples(sample_id, NUM_SAMPLES - 1)
  
  local split_at = string.match(file, "^.*()/")
  local folder = string.sub(file, 1, split_at)
  file = string.sub(file, split_at + 1)
  
  local found = false
  for k, v in ipairs(Timber.FileSelect.list) do
    if v == file then found = true end
    if found then
      if sample_id > 255 then
        print("Max")
        break
      end
      -- Check file type
      local lower_v = v:lower()
      if string.find(lower_v, ".wav") or string.find(lower_v, ".aif") or string.find(lower_v, ".aiff") then
        params:set("sample_" .. sample_id, folder .. v)
        sample_id = sample_id + 1
      else
        print("Skipped", v)
      end
    end
  end
end

local function set_sample_id(id)
  current_sample_id = id
  while current_sample_id >= NUM_SAMPLES do current_sample_id = current_sample_id - NUM_SAMPLES end
  while current_sample_id < 0 do current_sample_id = current_sample_id + NUM_SAMPLES end
  sample_setup_view:set_sample_id(current_sample_id)
  waveform_view:set_sample_id(current_sample_id)
  filter_amp_view:set_sample_id(current_sample_id)
  amp_env_view:set_sample_id(current_sample_id)
  mod_env_view:set_sample_id(current_sample_id)
  lfos_view:set_sample_id(current_sample_id)
  mod_matrix_view:set_sample_id(current_sample_id)
end

local function id_to_x(id)
  return (id - 1) % grid_w + 1
end
local function id_to_y(id)
  return math.ceil(id / grid_w)
end

local function note_on(sample_id, vel)
  if Timber.samples_meta[sample_id].num_frames > 0 then
    vel = vel or 1
    engine.noteOn(sample_id, sample_id, MusicUtil.note_num_to_freq(60), vel)
    sample_status[sample_id] = STATUS.PLAYING
    screen_dirty = true
    grid_dirty = true
  end
end

local function note_off(sample_id)
  engine.noteOff(sample_id)
  screen_dirty = true
  grid_dirty = true
end

local function clear_queue()
  
  for k, v in pairs(note_queue) do
    if Timber.samples_meta[v.sample_id].playing then
      sample_status[v.sample_id] = STATUS.PLAYING
    else
      sample_status[v.sample_id] = STATUS.STOPPED
    end
  end
  
  note_queue = {}
end

local function queue_note_event(event_type, sample_id, vel)
  
  local quant = options.QUANTIZATION_DIVIDERS[params:get("quantization_" .. sample_id)]
  if params:get("quantization_" .. sample_id) > 1 then
    
    -- Check for already queued
    for i = #note_queue, 1, -1 do
      if note_queue[i].sample_id == sample_id then
        if note_queue[i].event_type ~= event_type then
          table.remove(note_queue, i)
          if Timber.samples_meta[sample_id].playing then
            sample_status[sample_id] = STATUS.PLAYING
          else
            sample_status[sample_id] = STATUS.STOPPED
          end
          grid_dirty = true
        end
        return
      end
    end
    
    if event_type == "on" or sample_status[sample_id] == STATUS.PLAYING then
      if Timber.samples_meta[sample_id].num_frames > 0 then
        local note_event = {
          event_type = event_type,
          sample_id = sample_id,
          vel = vel,
          quant = quant
        }
        table.insert(note_queue, note_event)
        
        if event_type == "on" then
          sample_status[sample_id] = STATUS.STARTING
        else
          sample_status[sample_id] = STATUS.STOPPING
        end
      end
    end
    
  else
    if event_type == "on" then
      note_on(sample_id, vel)
    else
      note_off(sample_id)
    end
  end
  grid_dirty = true
end

local function note_off_all()
  engine.noteOffAll()
  clear_queue()
  screen_dirty = true
  grid_dirty = true
end

local function note_kill_all()
  engine.noteKillAll()
  clear_queue()
  screen_dirty = true
  grid_dirty = true
end

local function set_pressure_voice(voice_id, pressure)
  engine.pressureVoice(voice_id, pressure)
end

local function set_pressure_sample(sample_id, pressure)
  engine.pressureSample(sample_id, pressure)
end

local function set_pressure_all(pressure)
  engine.pressureAll(pressure)
end

local function set_pitch_bend_voice(voice_id, bend_st)
  engine.pitchBendVoice(voice_id, MusicUtil.interval_to_ratio(bend_st))
end

local function set_pitch_bend_sample(sample_id, bend_st)
  engine.pitchBendSample(sample_id, MusicUtil.interval_to_ratio(bend_st))
end

local function set_pitch_bend_all(bend_st)
  engine.pitchBendAll(MusicUtil.interval_to_ratio(bend_st))
end

local function key_down(sample_id, vel)
  if params:get("launch_mode_" .. sample_id) == 1 then
    queue_note_event("on", sample_id, vel)
    
  else
    if (sample_status[sample_id] ~= STATUS.PLAYING and sample_status[sample_id] ~= STATUS.STARTING) or sample_status[sample_id] == STATUS.STOPPING then
      queue_note_event("on", sample_id, vel)
    else
      queue_note_event("off", sample_id)
    end
  end
  
  if params:get("follow") == 2 then
    set_sample_id(sample_id)
  end
end

local function key_up(sample_id)
  if params:get("launch_mode_" .. sample_id) == 1 and params:get("play_mode_" .. sample_id) ~= 4 then
    queue_note_event("off", sample_id)
  end
end


-- Clock callbacks

local function advance_step()
  
  local tick = (beat_clock.beat * 24) + beat_clock.step -- 0-95
  
  -- Fire quantized note on/offs
  for i = #note_queue, 1, -1 do
    local note_event = note_queue[i]
    if tick % (96 / note_event.quant) == 0 then
      if note_event.event_type == "on" then
        note_on(note_event.sample_id, note_event.vel)
      else
        note_off(note_event.sample_id)
      end
      table.remove(note_queue, i)
    end
  end
  
  -- Every beat
  if beat_clock.step == 0 then
    if pages.index == 1 then screen_dirty = true end
  end
end

local function stop()
  note_kill_all()
end


-- Encoder input
function enc(n, delta)
  
  -- Global
  if n == 1 then
    if shift_mode then
      if pages.index > 1 then
        set_sample_id(current_sample_id + delta)
      end
    else
      pages:set_index_delta(delta, false)
    end
  
  else
    
    if pages.index == 1 then
      global_view:enc(n, delta)
    elseif pages.index == 2 then
      sample_setup_view:enc(n, delta)
    elseif pages.index == 3 then
      waveform_view:enc(n, delta)
    elseif pages.index == 4 then
      filter_amp_view:enc(n, delta)
    elseif pages.index == 5 then
      amp_env_view:enc(n, delta)
    elseif pages.index == 6 then
      mod_env_view:enc(n, delta)
    elseif pages.index == 7 then
      lfos_view:enc(n, delta)
    elseif pages.index == 8 then
      mod_matrix_view:enc(n, delta)
    end
    
  end
  screen_dirty = true
end

-- Key input
function key(n, z)
  
  if n == 1 then
    
    -- Shift
    if z == 1 then
      shift_mode = true
      Timber.shift_mode = shift_mode
    else
      shift_mode = false
      Timber.shift_mode = shift_mode
    end
    
  else
    
    if pages.index == 1 then
      global_view:key(n, z)
    elseif pages.index == 2 then
      sample_setup_view:key(n, z)
    elseif pages.index == 3 then
      waveform_view:key(n, z)
    elseif pages.index == 4 then
      filter_amp_view:key(n, z)
    elseif pages.index == 5 then
      amp_env_view:key(n, z)
    elseif pages.index == 6 then
      mod_env_view:key(n, z)
    elseif pages.index == 7 then
      lfos_view:key(n, z)
    end
  end
  
  screen_dirty = true
end

-- MIDI input
local function midi_event(data)
  
  local msg = midi.to_msg(data)
  local channel_param = params:get("midi_in_channel")
  
  if channel_param == 1 or (channel_param > 1 and msg.ch == channel_param - 1) then
    
    -- Note off
    if msg.type == "note_off" then
      key_up(msg.note)
    
    -- Note on
    elseif msg.type == "note_on" then
      key_down(msg.note, msg.vel / 127)
      
    -- Key pressure
    elseif msg.type == "key_pressure" then
      set_pressure_voice(msg.note, msg.val / 127)
      
    -- Channel pressure
    elseif msg.type == "channel_pressure" then
      set_pressure_all(msg.val / 127)
      
    -- Pitch bend
    elseif msg.type == "pitchbend" then
      local bend_st = (util.round(msg.val / 2)) / 8192 * 2 -1 -- Convert to -1 to 1
      local bend_range = params:get("bend_range")
      set_pitch_bend_sample(msg.note, bend_st * bend_range)
      
    end
  end

end

-- Grid event
local function grid_event(x, y, z)
  local sample_id = (y - 1) * grid_w + x - 1
  if z == 1 then
    key_down(sample_id)
  else
    key_up(sample_id)
  end
end

local function update()
  waveform_view:update()
  lfos_view:update()
end

function grid_redraw()
  
  if grid_device then
    grid_w = grid_device.cols
    grid_h = grid_device.rows
    if grid_w ~= 8 and grid_w ~= 16 then grid_w = 16 end
    if grid_h ~= 8 and grid_h ~= 16 then grid_h = 8 end
  end
  
  local leds = {}
  local num_leds = grid_w * grid_h
  
  for i = 1, num_leds do
    if sample_status[i - 1] == STATUS.STOPPING then
      leds[i] = 8
    elseif sample_status[i - 1] == STATUS.STARTING or sample_status[i - 1] == STATUS.PLAYING then
      leds[i] = 15
    elseif Timber.samples_meta[i - 1].num_frames > 0 then
      leds[i] = 4
    end
  end
  
  grid_device.all(0)
  for k, v in pairs(leds) do
    grid_device.led(id_to_x(k), id_to_y(k), v)
  end
  grid_device.refresh()
end


local function callback_set_screen_dirty(id)
  if id == nil or id == current_sample_id or pages.index == 1 then
    screen_dirty = true
  end
end

local function callback_set_waveform_dirty(id)
  if (id == nil or id == current_sample_id) and pages.index == 3 then
    screen_dirty = true
  end
end


-- Views

local GlobalView = {}
GlobalView.__index = GlobalView

function GlobalView.new()
  local global = {}
  setmetatable(GlobalView, {__index = GlobalView})
  setmetatable(global, GlobalView)
  return global
end

function GlobalView:enc(n, delta)
  if n == 3 and beat_clock.external == false then
    params:delta("bpm", delta)
  end
  callback_set_screen_dirty(nil)
end

function GlobalView:key(n, z)
  if z == 1 then
    if n == 2 then
        file_select_active = true
        local add = shift_mode
        shift_mode = false
        Timber.shift_mode = shift_mode
        Timber.FileSelect.enter(_path.audio, function(file)
          file_select_active = false
          screen_dirty = true
          if file ~= "cancel" then
            load_folder(file, add)
          end
        end)
      
    elseif n == 3 then
      if not beat_clock.external then
        if beat_clock.playing then
          beat_clock:stop()
          beat_clock:reset()
        else
          beat_clock:start()
        end
      end
    end
    callback_set_screen_dirty(nil)
  end
end

function GlobalView:redraw()
  
  -- Beat visual
  for i = 1, 4 do
    
    if beat_clock.playing and i == beat_clock.beat + 1 then
      screen.level(15)
      screen.rect(67 + (i - 1) * 12, 19, 4, 4)
    else
      screen.level(3)
      screen.rect(68 + (i - 1) * 12, 20, 2, 2)
    end
    screen.fill()
  end
  
  -- Grid or text prompt
  
  local num_to_draw = NUM_SAMPLES
  
  if grid_device.device then
    num_to_draw = grid_w * grid_h
  end
  
  local draw_grid = false
  for i = 1, num_to_draw do
    if Timber.samples_meta[i - 1].num_frames > 0 then
      draw_grid = true
      break
    end
  end
  
  if draw_grid then
    
    local LEFT = 4
    local top = 8
    local SIZE = 2
    local GUTTER = 1
    
    if grid_device.device and grid_h <= 8 then top = top + 12 end
    
    local x, y = LEFT, top
    for i = 1, num_to_draw do
      
      if sample_status[i - 1] == STATUS.STOPPING then
        screen.level(8)
      elseif sample_status[i - 1] == STATUS.STARTING or sample_status[i - 1] == STATUS.PLAYING then
        screen.level(15)
      elseif Timber.samples_meta[i - 1].num_frames > 0 then
        screen.level(3)
      else
        screen.level(1)
      end
      screen.rect(x, y, SIZE, SIZE)
      screen.fill()
      
      x = x + SIZE + GUTTER
      if i % grid_w == 0 then
        x = LEFT
        y = y + SIZE + GUTTER
      end
    end
    
  else
    
    screen.level(3)
    screen.move(4, 28)
    screen.text("KEY2 to")
    screen.move(4, 37)
    if shift_mode then
      screen.text("add folder")
    else
      screen.text("load folder")
    end
    screen.fill()
    
  end
  
  -- Info
  screen.move(68, 37)
  if beat_clock.external then
    screen.level(3)
    screen.text("External")
  else
    screen.level(15)
    screen.text(params:get("bpm") .. " BPM")
  end
  
  screen.fill()
end


-- Drawing functions

local function draw_background_rects()
  -- 4px edge margins. 8px gutter.
  screen.level(1)
  screen.rect(4, 22, 56, 38)
  screen.rect(68, 22, 56, 38)
  screen.fill()
end

function redraw()
  
  screen.clear()
  
  if file_select_active or Timber.file_select_active then
    Timber.FileSelect.redraw()
    return
  end
  
  -- draw_background_rects()
  
  pages:redraw()
  
  if pages.index == 1 then
    global_view:redraw()
  elseif pages.index == 2 then
    sample_setup_view:redraw()
  elseif pages.index == 3 then
    waveform_view:redraw()
  elseif pages.index == 4 then
    filter_amp_view:redraw()
  elseif pages.index == 5 then
    amp_env_view:redraw()
  elseif pages.index == 6 then
    mod_env_view:redraw()
  elseif pages.index == 7 then
    lfos_view:redraw()
  elseif pages.index == 8 then
    mod_matrix_view:redraw()
  end
  
  screen.update()
end


function init()
  
  midi_in_device = midi.connect(1)
  midi_in_device.event = midi_event
  
  midi_clock_in_device = midi.connect(1)
  midi_clock_in_device.event = function(data)
    beat_clock:process_midi(data)
    if not beat_clock.playing then
      screen_dirty = true
    end
  end
  
  midi_clock_out_device = midi.connect(1)
  midi_clock_out_device.event = function() end
  
  grid_device = grid.connect(1)
  grid_device.event = grid_event
  
  pages = UI.Pages.new(1, 8)
  
  -- Clock
  beat_clock = BeatClock.new()
  
  beat_clock.on_step = advance_step
  beat_clock.on_stop = stop
  beat_clock.on_select_internal = function()
    beat_clock:start()
    if pages.index == 1 then screen_dirty = true end
  end
  beat_clock.on_select_external = function()
    beat_clock:reset()
    if pages.index == 1 then screen_dirty = true end
  end
  
  beat_clock.ticks_per_step = 1
  beat_clock.steps_per_beat = 96 / 4 -- 96ths
  beat_clock:bpm_change(beat_clock.bpm)
  Timber.set_bpm(beat_clock.bpm)
  
  -- Timber callbacks
  Timber.sample_changed_callback = function(id)
    
    -- Set loop default based on sample length or name
    if Timber.samples_meta[id].streaming == 0 and Timber.samples_meta[id].num_frames / Timber.samples_meta[id].sample_rate < 1 and string.find(string.lower(params:get("sample_" .. id)), "loop") == nil then
      params:set("play_mode_" .. id, 3) -- One shot
    end
    
    grid_dirty = true
    callback_set_screen_dirty(id)
  end
  Timber.meta_changed_callback = function(id)
    if Timber.samples_meta[id].playing and sample_status[id] ~= STATUS.STOPPING then
      sample_status[id] = STATUS.PLAYING
    elseif not Timber.samples_meta[id].playing and sample_status[id] ~= STATUS.STARTING then
      sample_status[id] = STATUS.STOPPED
    end
    grid_dirty = true
    callback_set_screen_dirty(id)
  end
  Timber.waveform_changed_callback = callback_set_waveform_dirty
  Timber.play_positions_changed_callback = callback_set_waveform_dirty
  Timber.views_changed_callback = callback_set_screen_dirty
  
  -- Add params
  
  params:add{type = "number", id = "grid_device", name = "Grid Device", min = 1, max = 4, default = 1,
    action = function(value)
      grid_device.all(0)
      grid_device.refresh()
      grid_device:reconnect(value)
    end}
  params:add{type = "number", id = "midi_in_device", name = "MIDI In Device", min = 1, max = 4, default = 1,
    action = function(value)
      midi_in_device:reconnect(value)
    end}
  local channels = {"All"}
  for i = 1, 16 do table.insert(channels, i) end
  params:add{type = "option", id = "midi_in_channel", name = "MIDI In Channel", options = channels}
    
  params:add{type = "number", id = "clock_midi_in_device", name = "MIDI Clock In Device", min = 1, max = 4, default = 1,
    action = function(value)
      midi_clock_in_device:reconnect(value)
    end}
    
  params:add{type = "number", id = "midi_clock_out_device", name = "MIDI Clock Out Device", min = 1, max = 4, default = 1,
    action = function(value)
      midi_clock_out_device:reconnect(value)
    end}
  
  params:add{type = "option", id = "clock", name = "Clock", options = {"Internal", "External"}, default = beat_clock.external or 2 and 1,
    action = function(value)
      beat_clock:clock_source_change(value)
    end}
  
  params:add{type = "option", id = "clock_out", name = "Clock Out", options = options.OFF_ON, default = beat_clock.send or 2 and 1,
    action = function(value)
      if value == 1 then beat_clock.send = false
      else beat_clock.send = true end
    end}
  
  params:add_separator()
  
  params:add{type = "number", id = "bpm", name = "BPM", min = 1, max = 240, default = beat_clock.bpm,
    action = function(value)
      beat_clock:bpm_change(value)
      Timber.set_bpm(beat_clock.bpm)
      if pages.index == 1 then screen_dirty = true end
    end}
    
  params:add{type = "number", id = "bend_range", name = "Pitch Bend Range", min = 1, max = 48, default = 2}
  
  params:add{type = "option", id = "follow", name = "Follow", options = options.OFF_ON, default = 2}
  
  params:add_separator()
  
  Timber.add_params()
  -- Index zero to align with MIDI note numbers
  for i = 0, NUM_SAMPLES - 1 do
    local extra_params = {
      {type = "option", id = "launch_mode_" .. i, name = "Launch Mode", options = {"Gate", "Toggle"}, default = 1, action = function(value)
        Timber.setup_params_dirty = true
      end},
      {type = "option", id = "quantization_" .. i, name = "Quantization", options = options.QUANTIZATION, default = 1, action = function(value)
        if value == 1 then
          for n = #note_queue, 1, -1 do
            if note_queue[n].sample_id == i then
              table.remove(note_queue, n)
              if Timber.samples_meta[i].playing then
                sample_status[i] = STATUS.PLAYING
              else
                sample_status[i] = STATUS.STOPPED
              end
              grid_dirty = true
            end
          end
        end
        Timber.setup_params_dirty = true
      end}
    }
    params:add_separator()
    Timber.add_sample_params(i, true, extra_params)
  end
    
  -- TODO Stream startup tests
  -- params:set("sample_0", "/home/we/dust/audio/mark_eats/Tests/rim-buffer.aif")
  -- params:set("sample_1", "/home/we/dust/audio/mark_eats/Tests/rim-stream.aif")
  
  params:set("sample_0", "/home/we/dust/audio/common/808/808-BD.wav")
  params:set("sample_1", "/home/we/dust/audio/common/808/808-SD.wav")
  params:set("sample_2", "/home/we/dust/audio/common/808/808-CB.wav")
  params:set("sample_3", "/home/we/dust/audio/common/808/808-CH.wav")
  params:set("sample_4", "/home/we/dust/audio/common/808/808-OH.wav")
  params:set("sample_5", "/home/we/dust/audio/common/808/808-CY.wav")
  params:set("sample_6", "/home/we/dust/audio/common/808/808-CL.wav")
  params:set("sample_7", "/home/we/dust/audio/common/808/808-CP.wav")
  params:set("sample_8", "/home/we/dust/audio/common/808/808-LC.wav")
  params:set("sample_9", "/home/we/dust/audio/common/808/808-MC.wav")
  params:set("sample_10", "/home/we/dust/audio/common/808/808-HC.wav")
  params:set("sample_11", "/home/we/dust/audio/common/808/808-LT.wav")
  params:set("sample_12", "/home/we/dust/audio/common/808/808-MT.wav")
  params:set("sample_13", "/home/we/dust/audio/common/808/808-HT.wav")
  params:set("sample_14", "/home/we/dust/audio/common/808/808-MA.wav")
  params:set("sample_15", "/home/we/dust/audio/common/808/808-RS.wav")
  params:set("sample_32", "/home/we/dust/audio/mark_eats/Tests/piano-c.wav")
  params:set("sample_33", "/home/we/dust/audio/mark_eats/Tests/piano-c-rev.wav")
  params:set("sample_34", "/home/we/dust/audio/mark_eats/Tests/loop-long.wav")
  params:set("sample_35", "/home/we/dust/audio/mark_eats/Tests/loop-short.wav")
  params:set("sample_36", "/home/we/dust/audio/mark_eats/Tests/count.wav")
  -- params:set("sample_0", "/home/we/dust/audio/mark_eats/Tests/metro-test-4-bars-110bpm.aif")
  -- params:set("sample_1", "/home/we/dust/audio/mark_eats/Tests/metro-test-8-bars-110bpm.aif")
  
  
  -- UI
  
  global_view = GlobalView.new()
  sample_setup_view = Timber.UI.SampleSetup.new(current_sample_id, nil)
  waveform_view = Timber.UI.Waveform.new(current_sample_id)
  filter_amp_view = Timber.UI.FilterAmp.new(current_sample_id)
  amp_env_view = Timber.UI.AmpEnv.new(current_sample_id)
  mod_env_view = Timber.UI.ModEnv.new(current_sample_id)
  lfos_view = Timber.UI.Lfos.new(current_sample_id)
  mod_matrix_view = Timber.UI.ModMatrix.new(current_sample_id)
  
  screen.aa(1)
  
  local screen_redraw_metro = metro.init()
  screen_redraw_metro.event = function()
    update()
    if screen_dirty then
      redraw()
      screen_dirty = false
    end
  end
  
  local grid_redraw_metro = metro.init()
  grid_redraw_metro.event = function()
    if grid_dirty and grid_device.device then
      grid_dirty = false
      grid_redraw()
    end
  end
  
  screen_redraw_metro:start(1 / SCREEN_FRAMERATE)
  grid_redraw_metro:start(1 / GRID_FRAMERATE)
  
  beat_clock:start()
  
end