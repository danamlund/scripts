-- View combat reports for currently selected unit
--[====[

view-unit-reports
=================
Show combat reports for the current unit.

Current unit is unit near cursor in 'v', selected in 'u' list,
unit/corpse/splatter at cursor in 'k'. And newest unit with race when
'k' at race-specific blood spatter.

]====]

local function get_combat_logs(unit)
   local output = {}
   for _,report_id in pairs(unit.reports.log.Combat) do
      local report = df.report.find(report_id)
      if report then
         output[#output + 1] = report
      end
   end
   return output
end

local function view_unit_report(unit)
   local report_view = df.viewscreen_announcelistst:new()
   report_view.unit = unit

   for _,report in pairs(get_combat_logs(unit)) do
      report_view.reports:insert('#', report)
   end

   report_view.sel_idx = #report_view.reports - 1

   dfhack.screen.show(report_view)
end

local function find_last_unit_with_combat_log_and_race(race_id)
   local output = nil
   for _, unit in pairs(df.global.world.units.all) do
      if unit.race == race_id and #get_combat_logs(unit) >= 1 then
         output = unit
      end
   end
   return output
end

local function current_selected_unit()
    local unit_item_viewer = reqscript 'gui/unit-info-viewer'
    return unit_item_viewer.getUnit_byVS(true)
end

local unit = current_selected_unit()
if unit then
   view_unit_report(unit)
end
