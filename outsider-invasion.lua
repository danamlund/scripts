-- Spawn an invasion army scaled to population and wealth
--@ enable = true

local usage = [====[

outsider-invasion
=================
Spawns an invasion army scaled to the population and wealth of your fortress.
Note: this is not an official dwarf fortress invasion, it is just units spawned 
out of nowhere (like adventure mode outsiders).

Sending an invasion crashes quite often, make sure you save often.

Scaling works by adding more units (up to invasion cap from
d_init.txt), by giving invaders better gear, and higher skills, and by
sending stronger monsters. However, gear, skills, and monsters peak,
so a strength above a certain number does nothing.

Running with no args shows status. You have to use ``-now`` to trigger
an invasion.

Arguments:

    -help
    -now
        Send an invasion right now.
    -invasion-type <string>
        Type of army to invade.
        Options: random, goblins (default), elves, semimegabeasts
    -difficulty <float>
        Scale the difficult of the invasion army.
        examples: 0.5 is half as difficult, 2.0 is twice as difficult
    -cap number
        Set the maximum number of invaders.
    -dry-run
        Do not send the invasion, just generate and print an invasion army.
    -strength number
        Override dynamic scaling of army difficulty and set to fixed number.
        1 is the smallest army possible. Strength 1000 kills about 10% of my 
        4 squads with steel weapons, little armor, and about master-level skills.
        Note: -difficulty have no affect when -strength is set.
    -arena-side number
        Set the arena side for the invasion army when in arena mode.
        In arena mode the army spawns at cursor and -strength is required.
    -every-months <months>
        Send an invasion every <months> months but not now.
        Set to 0 to disable automatically sending invasions.
        Enabling this will save the state to the fortress and continue after
          loading the fortress. But only if you add ``outsider-invasion``
          to your ``dfhack.init`` file.
        This option understands ``-invasion-type`` and ``-difficulty``.
        Only one auto invasion can be active at a time.
        Warning: Not recommended due to frequency crashes when sending invasion.

Examples:

    Spawn an invasion scaled to your fort
        outsider-invasion -now

    Spawn a very very difficult goblin invasion
        outsider-invasion -now -invasion-type goblins -strength 10000 -cap 300

    Setup an invasion every 10 months
        outsider-invasion -every-months 10

    Setup an invasion every 10 months for all current and future forts
        add ``outsider-invasion -every-months 10`` to your dfhack.init
        file.  Setting everyMonths to what is already is does not
        reset the date for the next invasion.

]====]
--[[
   BUGS
   - It sometimes crashes dwarf fortress (or dfhack)
   - corrupts dwarves when activated while an alert window is open
   - Hardcoded creatures, weapons, armors, skills, and materials. 
     Might not work with mods.
   - Poorly simulated invasion behavior
   - Building destroyers do not destroy buildings
   - Civilians attack/ignore invaders (because each invader only targets 
     one dwarf at a time)
   - Invaders rush the fort (real invasions use complicated behaviors)
   - Could not get creatures without CAN_LEARN or INTELLIGENT to stop
     attacking each other, so no unicorns and cave dragons
   - Balance probably needs some work
--]]

local VERSION = "1.0"

local utils = require 'utils'
local dlg = require 'gui.dialogs'

local dryRun = false
local logTrace = false

local spawnedUnitsDates = { }

local professionsToId = {
   HAMMERMAN = 75,
   SPEARMAN = 77,
   CROSSBOWMAN = 79,
   WRESTLER = 81,
   AXEMAN = 83,
   SWORDSMAN = 85,
   MACEMAN = 87,
   PIKEMAN = 89,
   BOWMAN = 91,
   BLOWGUNMAN = 93,
   LASHER = 95,
   RECRUIT = 97,
}

local monsterClass = {
   professionId = professionsToId.WRESTLER,
   skillModifier = 1.0,
   primarySkills = { "WRESTLING", "BITE" },
   primaryAttributes = { },
   weapon = { },
}

local invaderClasses = {
   {
      professionId = professionsToId.WRESTLER,
      skillModifier = 1.5,
      primarySkills = { "WRESTLING", "DODGING" },
      primaryAttributes = { },
      weapon = { },
   },
   {
      professionId = professionsToId.BOWMAN,
      skillModifier = 1.0,
      primarySkills = { "BOW", "THROWS" },
      primaryAttributes = { },
      weapon = { "WEAPON:ITEM_WEAPON_BOW" },
   },
   {
      professionId = professionsToId.AXEMAN,
      skillModifier = 1.0,
      primarySkills = { "AXE", "ARMOR" },
      primaryAttributes = { },
      weapon = { "WEAPON:ITEM_WEAPON_HALBERD" },
   },
   {
      professionId = professionsToId.SWORDSMAN,
      skillModifier = 1.0,
      primarySkills = { "SWORD", "SHIELD" },
      primaryAttributes = { },
      weapon = { "WEAPON:ITEM_WEAPON_SCIMITAR", "SHIELD:ITEM_SHIELD_SHIELD" },
   },
   {
      professionId = professionsToId.SWORDSMAN,
      skillModifier = 1.3,
      primarySkills = { "DAGGER", "DODGING", "MELEE_COMBAT" },
      primaryAttributes = { },
      weapon = { "WEAPON:ITEM_WEAPON_DAGGER_LARGE", "WEAPON:ITEM_WEAPON_DAGGER_LARGE" },
   },
   {
      professionId = professionsToId.MACEMAN,
      skillModifier = 1.0,
      primarySkills = { "MACE", "SHIELD" },
      primaryAttributes = { },
      weapon = { "WEAPON:ITEM_WEAPON_MORNINGSTAR", "SHIELD:ITEM_SHIELD_SHIELD" },
   },
   {
      professionId = professionsToId.PIKEMAN,
      skillModifier = 1.0,
      primarySkills = { "PIKE", "ARMOR" },
      primaryAttributes = { },
      weapon = { "WEAPON:ITEM_WEAPON_PIKE" },
   },
   {
      professionId = professionsToId.LASHER,
      skillModifier = 0.5,
      primarySkills = { "WHIP" },
      primaryAttributes = { },
      weapon = { "WEAPON:ITEM_WEAPON_WHIP" },
   }
}

function getFortressStrength(difficulty)
   local population = df.global.ui.tasks.population
   local wealth = df.global.ui.tasks.wealth.total - df.global.ui.tasks.wealth.imported

   local strength = math.max(1, (population - 20) * 10 + wealth / 5000)
   return math.round(strength * difficulty)
end

function getFortressMaxInvasionCap()
   return df.global.d_init.invasion_soldier_cap[2] + df.global.d_init.invasion_monster_cap[2]
end

function trace(msg)
   if logTrace then
      print(msg)
   end
end

-- strength = 1000 is about a normal siege
function goblinInvasion(x, y, z, strength, maxUnitsNumber, arenaSide)
   local unitsMax = math.round(strength / 15)
   local unitsNumber = math.random(math.max(3, unitsMax - 20), math.max(4, unitsMax))
   if unitsNumber > maxUnitsNumber then
      unitsNumber = maxUnitsNumber
   end

   local strengthPerUnit = 10 * strength / unitsNumber

   local monsters = {
      -- { race = "CAVE_DRAGON", strength = 500 }, -- cave dragons seem to attack other invaders
      { race = "OGRE", strength = 1 },
      -- { race = "TROLL", strength = 1 },
   }
   local monstersNumber = math.round(unitsNumber / 20)
   unitsNumber = unitsNumber - monstersNumber

   createMonsters(x, y, z, monsters, strengthPerUnit, monstersNumber, arenaSide)
   
   for i = 1, unitsNumber do
      local race = pickRandom({ GOBLIN = 50, TROLL = 5, DWARF = 1, HUMAN = 1, ELF = 1 })
      local caste = pickRandom({ MALE = 1, FEMALE = 1 })
      local unit = createInvader(x, y, z, race, caste, "EVIL", arenaSide)
      local class = invaderClasses[math.random(#invaderClasses)]

      if not dryRun then
         unit.profession = class.professionId
         unit.profession2 = unit.profession
      end
      
      if i == unitsNumber and unitsNumber > 50 then
         local profession
         if unitsNumber > 200 then
            profession = "Warmaster"
         elseif unitsNumber > 100 then
            profession = "General"
         else
            profession = "Leader"
         end
         if not dryRun then
            unit.custom_profession = profession
         end
         trace("* race=" .. race
                  .. ", caste=" .. caste
                  .. ", class=" .. class.primarySkills[1]
                  .. ", leader=" .. profession)

         local leaderMaterials = { "INORGANIC:SILVER", "INORGANIC:GOLD", "INORGANIC:PLATINUM" }
         
         setUnitSkills(unit, 5.0 * strengthPerUnit, class)
         setUnitAttributes(unit, 5.0 * strengthPerUnit, class)
         setUnitWeapons(unit, 5.0 * strengthPerUnit, class, leaderMaterials)
         setUnitArmor(unit, 5.0 * strengthPerUnit, class, leaderMaterials)
         setUnitJewelry(unit, 10.0 * strengthPerUnit)
      else
         trace("* race=" .. race
                  .. ", caste=" .. caste
                  .. ", class=" .. class.primarySkills[1])
         setUnitSkills(unit, strengthPerUnit, class)
         setUnitAttributes(unit, strengthPerUnit, class)
         setUnitWeapons(unit, strengthPerUnit, class)
         setUnitArmor(unit, strengthPerUnit, class)
         setUnitJewelry(unit, strengthPerUnit)
      end
      trace("")
   end

   trace("* Goblin invasion")
   trace("Goblins: " .. unitsNumber)
   trace("Monsters: " .. monstersNumber)
   trace("Strength: " .. strength)
   trace("Strength per unit: " .. strengthPerUnit)
end

-- elves have wooden weapons and armor but very high skill
function elfInvasion(x, y, z, strength, maxUnitsNumber, arenaSide)
   local invaderClasses = {
      {
         professionId = professionsToId.BOWMAN,
         skillModifier = 1.0,
         primarySkills = { "BOW", "THROWS" },
         primaryAttributes = { },
         weapon = { "WEAPON:ITEM_WEAPON_BOW" },
      },
      {
         professionId = professionsToId.HAMMERMAN,
         skillModifier = 1.0,
         primarySkills = { "HAMMER", "SHIELD" },
         primaryAttributes = { },
         weapon = { "WEAPON:ITEM_WEAPON_HAMMER_WAR", "SHIELD:ITEM_SHIELD_SHIELD" },
      },
   }

   local materials = { "PLANT_MAT:WILLOW:WOOD", "PLANT_MAT:OAK:WOOD", "PLANT_MAT:GLUMPRONG:WOOD" }
   
   local unitsMax = math.round(strength / 15)
   local unitsNumber = math.random(math.max(3, unitsMax - 20), math.max(4, unitsMax))
   if unitsNumber > maxUnitsNumber then
      unitsNumber = maxUnitsNumber
   end

   local strengthPerUnit = 80 * strength / unitsNumber

   local function getQualityFunc()
      local center = math.max(0, math.min(1, strength / 2000))
      return math.round(getDistValue(center, 5) * 5)
   end
   local function getQualityFuncLeader()
      local center = math.max(0, math.min(1, 5 * strength / 2000))
      return math.round(getDistValue(center, 5) * 5)
   end
   
   -- Unicorns seem to attach other invaders, so no monsters
   for i = 1, unitsNumber do
      local race = "ELF"
      local caste = pickRandom({ MALE = 1, FEMALE = 1 })
      local name = "FOREST"
      local unit = createInvader(x, y, z, race, caste, name, arenaSide)
      local class = invaderClasses[math.random(#invaderClasses)]

      if not dryRun then
         unit.profession = class.professionId
         unit.profession2 = unit.profession
      end
      
      if i == unitsNumber and unitsNumber > 50 then
         local profession;
         if unitsNumber > 200 then
            profession = "Indigo invader"
         elseif unitsNumber > 100 then
            profession = "Wood warrior"
         else
            profession = "Rainbow roughian"
         end
         if not dryRun then
            unit.custom_profession = profession
         end
         trace("* race=" .. race
                  .. ", caste=" .. caste
                  .. ", class=" .. class.primarySkills[1]
                  .. ", leader=" .. profession)

         setUnitSkills(unit, 5.0 * strengthPerUnit, class)
         setUnitAttributes(unit, 5.0 * strengthPerUnit, class)
         setUnitWeapons(unit, 5.0 * strengthPerUnit, class, materials, getQualityFuncLeader)
         setUnitArmor(unit, 5.0 * strengthPerUnit, class, materials, getQualityFuncLeader)
         setUnitJewelry(unit, 10.0 * strengthPerUnit)
      else
         trace("* race=" .. race
                  .. ", caste=" .. caste
                  .. ", class=" .. class.primarySkills[1])
         setUnitSkills(unit, strengthPerUnit, class)
         setUnitAttributes(unit, strengthPerUnit, class)
         setUnitWeapons(unit, strengthPerUnit, class, materials, getQualityFunc)
         setUnitArmor(unit, strengthPerUnit, class, materials, getQualityFunc)
         setUnitJewelry(unit, strengthPerUnit)
      end
      trace("")
   end

   trace("* Elven invasion")
   trace("Elves: " .. unitsNumber)
   trace("Strength: " .. strength)
   trace("Strength per unit: " .. strengthPerUnit)
end

-- beasts attack other not of its kind. So can only spawn one beast type at a time.
function semiMegaBeastInvasion(x, y, z, strength, maxUnitsNumber, arenaSide)

   local axemanClass = {
      professionId = professionsToId.AXEMAN,
      skillModifier = 1.0,
      primarySkills = { "AXE" },
      primaryAttributes = { },
      weapon = { "WEAPON:ITEM_WEAPON_AXE_GREAT" },
   }

   local semimegabeasts = {
      {
         race = "MINOTAUR",
         unitsMaxMultiplier = 1/80,
         class = axemanClass
      },
      {
         race = "ETTIN",
         unitsMaxMultiplier = 1/160,
         class = monsterClass
      },
      {
         race = "CYCLOPS",
         unitsMaxMultiplier = 1/160,
         class = monsterClass
      },
      {
         race = "GIANT",
         unitsMaxMultiplier = 1/200,
         class = monsterClass
      },
   }

   local beast = semimegabeasts[math.random(#semimegabeasts)]
   beast = semimegabeasts[4]

   local unitsMax = math.round(strength * beast.unitsMaxMultiplier)
   local unitsNumber = math.random(math.round(math.max(1, unitsMax * 0.7)),
                                   math.round(math.max(1, unitsMax)))
   if unitsNumber > maxUnitsNumber then
      unitsNumber = maxUnitsNumber
   end
   local strengthPerUnit = 5 * strength / unitsNumber

   for i = 1, unitsNumber do
      local caste = pickRandom({ MALE = 1, FEMALE = 1 })
      local name = "EVIL"
      local unit = createInvader(x, y, z, beast.race, caste, name, arenaSide)
      
      trace("* race=" .. beast.race
               .. ", caste=" .. caste
               .. ", class=" .. beast.class.primarySkills[1]
               .. ", strength=" .. strengthPerUnit)
      if not dryRun then
         unit.profession = beast.class.professionId
         unit.profession2 = unit.profession
      end
      setUnitWeapons(unit, strengthPerUnit, beast.class)
      setUnitSkills(unit, strengthPerUnit, beast.class)
      setUnitAttributes(unit, strengthPerUnit, beast.class)
      setUnitJewelry(unit, strengthPerUnit)

      trace("")
   end
   
   trace("* Semimegabeast invasion")
   trace("Semimegsbeasts: " .. unitsNumber)
   trace("Strength: " .. strength)
end

function createMonsters(x, y, z, races, strength, units, arenaSide)
   local strengthPerUnit = strength / units
   for i = 1, units do
      local caste = pickRandom({ MALE = 1, FEMALE = 1 })
      local validRaces = {}
      table.insert(validRaces, races[#races]) -- always add the weakest
      for _, v in pairs(races) do
         if v.strength < strengthPerUnit then
            table.insert(validRaces, v)
         end
      end
      local race = validRaces[math.random(#validRaces)]
      local unitStrength = strengthPerUnit - race.strength
      trace("* race=" .. race.race .. ", case=" .. caste .. ", strength=" .. unitStrength)
      local unit = createInvader(x, y, z, race.race, caste, null, arenaSide)
      setUnitSkills(unit, unitStrength, monsterClass)
      setUnitAttributes(unit, unitStrength, monsterClass)
      trace("")
      strength = strength - race.strength
      strengthPerUnit = strength / (units - i)
   end
end

function createInvader(x, y, z, race, caste, name, arenaSide)
   if dryRun then
      return null
   end
   
   local args = { "-location", "[", tostring(x), tostring(y), tostring(z), "]",
                  "-race", race,
                  "-caste", caste }
   if not dfhack.world.isArena() then
      -- with these flags enemies just dance or something in arena mode
      table.insert(args, "-flagSet")
      table.insert(args, "[")
      table.insert(args, "marauder")
      table.insert(args, "active_invader")
      table.insert(args, "invader_origin")
      table.insert(args, "invades")
      table.insert(args, "hidden_ambusher")
      table.insert(args, "]")
   end
   if name then
      table.insert(args, "-name")
      table.insert(args, name)
   end

   df.global.world.arena_spawn.side = arenaSide or 0
   
   dfhack.run_script('modtools/create-unit', table.unpack(args))
   local unit = df.global.world.units.all[#df.global.world.units.all - 1]

   return unit
end

function setUnitSkills(unit, strength, class)
   trace("** Skills")
   local isPrimarySkill = {}
   for _, v in pairs(class.primarySkills) do
      isPrimarySkill[v] = true
   end
   -- strength 1000 give legendary, is there an upper limit on skill?
   local baseLevel = class.skillModifier * strength / 70
   function doSetSkill(skill, onlyIfPrimary)
      if not onlyIfPrimary or isPrimarySkill[skill] then
         local level = math.round(baseLevel)
         if isPrimarySkill[skill] then
            level = math.round(math.max(2, baseLevel * 1.25))
         end
         setSkill(unit, skill, level)
         trace(" - " .. skill .. " = " .. level)
      end
   end

   function doSetSkillIfPrimary(skill)
      doSetSkill(skill, true)
   end
   

   doSetSkill("SWIMMING")
   doSetSkill("CLIMBING")

   doSetSkill("BITE")
   doSetSkill("MELEE_COMBAT") -- Fighter
   doSetSkill("WRESTLING")
   doSetSkill("GRASP_STRIKE") -- Striker
   doSetSkill("STANCE_STRIKE") -- Kicker

   doSetSkill("DODGING")
   doSetSkill("ARMOR")
   doSetSkill("SHIELD")

   doSetSkillIfPrimary("BOW")
   doSetSkillIfPrimary("THROW") -- Archer

   doSetSkillIfPrimary("AXE")
   doSetSkillIfPrimary("SWORD")
   doSetSkillIfPrimary("DAGGER")
   doSetSkillIfPrimary("MACE")
   doSetSkillIfPrimary("HAMMER")
   doSetSkillIfPrimary("SPEAR")
   doSetSkillIfPrimary("PIKE")
   doSetSkillIfPrimary("WHIP")
end

function multiplyAttribute(unit, attribute, multiplier)
   if dryRun then
      return
   end

   local attr = null
   if attribute == "STRENGTH" then
      attr = unit.body.physical_attrs.STRENGTH
   elseif attribute == "AGILITY" then
      attr = unit.body.physical_attrs.AGILITY
   elseif attribute == "TOUGHNESS" then
      attr = unit.body.physical_attrs.TOUGHNESS
   elseif attribute == "ENDURANCE" then
      attr = unit.body.physical_attrs.ENDURANCE
   elseif attribute == "RECUPERATION" then
      attr = unit.body.physical_attrs.RECUPERATION
   elseif attribute == "DISEASE_RESISTANCE" then
      attr = unit.body.physical_attrs.DISEASE_RESISTANCE
   elseif attribute == "ANALYTICAL_ABILITY" then
      attr = unit.status.current_soul.mental_attrs.ANALYTICAL_ABILITY
   elseif attribute == "FOCUS" then
      attr = unit.status.current_soul.mental_attrs.FOCUS
   elseif attribute == "WILLPOWER" then
      attr = unit.status.current_soul.mental_attrs.WILLPOWER
   elseif attribute == "CREATIVITY" then
      attr = unit.status.current_soul.mental_attrs.CREATIVITY
   elseif attribute == "INTUITION" then
      attr = unit.status.current_soul.mental_attrs.INTUITION
   elseif attribute == "PATIENCE" then
      attr = unit.status.current_soul.mental_attrs.PATIENCE
   elseif attribute == "MEMORY" then
      attr = unit.status.current_soul.mental_attrs.MEMORY
   elseif attribute == "LINGUISTIC_ABILITY" then
      attr = unit.status.current_soul.mental_attrs.LINGUISTIC_ABILITY
   elseif attribute == "SPATIAL_SENSE" then
      attr = unit.status.current_soul.mental_attrs.SPATIAL_SENSE
   elseif attribute == "MUSICALITY" then
      attr = unit.status.current_soul.mental_attrs.MUSICALITY
   elseif attribute == "KINESTHETIC_SENSE" then
      attr = unit.status.current_soul.mental_attrs.KINESTHETIC_SENSE
   elseif attribute == "EMPATHY" then
      attr = unit.status.current_soul.mental_attrs.EMPATHY
   elseif attribute == "SOCIAL_AWARENESS" then
      attr = unit.status.current_soul.mental_attrs.SOCIAL_AWARENESS
   else
      error("Invalid attribute: " .. tostring(attribute))
   end

   local newValue = math.round(attr.value * multiplier)
   if newValue > attr.max_value then
      newValue = attr.max_value
   end
   
   attr.value = newValue
end

function setUnitAttributes(unit, strength, class)
   trace("** Attributes")
   local isPrimaryAttribute = {}
   for _, v in pairs(class.primaryAttributes) do
      isPrimaryAttribute[v] = true
   end
   local baseMultiplier = 1.0 + class.skillModifier * (strength - 100) / 500
   function doSetAttribute(attribute)
      local multiplier = baseMultiplier
      if isPrimaryAttribute[attribute] then
         multiplier = baseMultiplier * 1.25
      end
      multiplyAttribute(unit, attribute, multiplier)
      trace(" - " .. attribute .. " *= " .. multiplier)
   end

   local attributes = {"STRENGTH", "AGILITY", "TOUGHNESS", "ENDURANCE", 
                       "FOCUS", "WILLPOWER", "SPATIAL_SENSE", "KINESTHETIC_SENSE" }

   for _, attribute in pairs(attributes) do
      doSetAttribute(attribute)
   end
end

function getRandomQuality()
   local quality = pickRandom({["0"] = 200, ["1"] = 50, ["2"] = 25, ["3"] = 12, ["4"] = 6, ["5"] = 3})
   return math.floor(quality)
end

function setUnitWeapons(unit, strength, class, materials, getQualityFunc)
   trace("** Weapons")
   local materials = materials or
      { "INORGANIC:COPPER", "INORGANIC:COPPER",
        "INORGANIC:BRONZE", "INORGANIC:BRONZE",
        "INORGANIC:IRON", "INORGANIC:IRON",
        "INORGANIC:STEEL" }
   local getQualityFunc = getQualityFunc or getRandomQuality
   local materialsCenter = strength / 200
   local material = pickOrderedDist(materials, materialsCenter, 10)

   function doGiveWeapon(weapon, bodyPart)
      local quality = getQualityFunc()
      trace(" - " .. weapon .. " of " .. material .. " quality=" .. df.item_quality[quality])
      giveWeapon(unit, weapon, material, quality, bodyPart)
      if weapon == "WEAPON:ITEM_WEAPON_BOW" then
         local quality = getRandomQuality()
         trace(" - and quiver with arrow of " .. material .. " quality=" .. df.item_quality[quality])
         giveQuiverWithArrows(unit, "CREATURE_MAT:DWARF:LEATHER", material, quality)
      end
   end
   
   if #class.weapon >= 1 then
      doGiveWeapon(class.weapon[1], "RH")
   end
   if #class.weapon >= 2 then
      doGiveWeapon(class.weapon[2], "LH")
   end
end

function setUnitArmor(unit, strength, class, materials, getQualityFunc)
   trace("** Armor")
   local materials = materials or
      { nil, nil,
        "CREATURE_MAT:DWARF:LEATHER",
        "INORGANIC:COPPER", "INORGANIC:COPPER",
        "INORGANIC:BRONZE", "INORGANIC:BRONZE",
        "INORGANIC:IRON", "INORGANIC:IRON",
        "INORGANIC:STEEL" }
   local getQualityFunc = getQualityFunc or getRandomQuality

   local function doGiveArmor(strengthModifier, item, bodyPart, leftOrRight)
      local materialsCenter = strengthModifier * strength / 200
      if materialsCenter > 0.8 then materialsCenter = 0.8 end
      local material = pickOrderedDist(materials, materialsCenter, 2)
      if material then
         local quality = getQualityFunc()
         
         trace(" - " .. item .. " of " .. material .. " quality=" .. df.item_quality[quality])
         giveArmor(unit, item, material, quality, bodyPart, leftOrRight)
      end
   end

   doGiveArmor(1.0, "HELM:ITEM_HELM_HELM", "HD")
   doGiveArmor(1.0, "ARMOR:ITEM_ARMOR_MAIL_SHIRT", "UB")
   doGiveArmor(0.5, "PANTS:ITEM_PANTS_LEGGINGS", "LB")
   doGiveArmor(0.2, "GLOVES:ITEM_GLOVES_GAUNTLETS", "LH", "left")
   doGiveArmor(0.2, "GLOVES:ITEM_GLOVES_GAUNTLETS", "RH", "right")
   doGiveArmor(0.1, "SHOES:ITEM_SHOES_BOOTS", "LF")
   doGiveArmor(0.1, "SHOES:ITEM_SHOES_BOOTS", "RF")
end

function setUnitJewelry(unit, strength)
   trace("** Jewelry")
   local metals = { "INORGANIC:NICKEL", "INORGANIC:SILVER",
                    "INORGANIC:GOLD", "INORGANIC:PLATINUM", "INORGANIC:ALUMINUM" }
   local gems = { "INORGANIC:BROWN JASPER", "INORGANIC:GREEN ZIRCON",
                  "INORGANIC:SAPPHIRE","INORGANIC:DIAMOND_CLEAR" }

   local necks = {}
   local wrists = {}
   local ears = {}
   local digits = {}
   local teeth = {}
   if unit then
      for _,v in pairs(unit.body.body_plan.body_parts) do
         if v.token == "NK" then
            table.insert(necks, v.token)
         elseif string.ends(v.token, "_J") then
            table.insert(wrists, v.token)
         elseif string.ends(v.token, "_EAR") then
            table.insert(ears, v.token)
         elseif string.starts(v.token, "FINGER") or string.starts(v.token, "TOE") then
            table.insert(digits, v.token)
         elseif string.ends(v.token, "TOOTH") then
            table.insert(teeth, v.token)
         end
      end
   else
      table.insert(necks, "NK")
      table.insert(wrists, "RH_J")
      table.insert(wrists, "LH_J")
      table.insert(ears, "R_EAR")
      table.insert(ears, "L_EAR")
      table.insert(digits, "FINGER1")
      table.insert(digits, "TOE1")
      table.insert(teeth, "U_F_TOOTH")
  end
   
   local jewelryTypes = {
      { item = "AMULET:NONE",
        materials = metals,
        bodyParts = necks
      },
      { item = "BRACELET:NONE",
        materials = metals,
        bodyParts = wrists
      },
      { item = "EARRING:NONE",
        materials = metals,
        bodyParts = ears
      },
      { item = "RING:NONE",
        materials = metals,
        bodyParts = digits
      },
      { item = "SMALLGEM:NONE",
        materials = gems,
        bodyParts = teeth
      }
   }
   for k, v in pairs(jewelryTypes) do
      if #v.bodyParts == 0 then
         table.remove(jewelryTypes, k)
      end
   end

   local jewelryNumber = math.min(10, math.random(0, math.round(strength / 100)))
   for i = 1, jewelryNumber do
      local jewelryType = jewelryTypes[math.random(#jewelryTypes)]
      
      local materialsCenter = strength / 200
      if materialsCenter > 0.8 then materialsCenter = 0.8 end
      local material = pickOrderedDist(jewelryType.materials, materialsCenter, 2)
      local quality = getRandomQuality()
      local bodyPart = jewelryType.bodyParts[math.random(#jewelryType.bodyParts)]
      
      trace(" - " .. jewelryType.item .. " on " .. bodyPart
               .. " of " .. material .. " quality=" .. df.item_quality[quality])
      giveArmor(unit, jewelryType.item, material, quality, bodyPart, leftOrRight)
   end
end

function setSkill(unit, skillName, level)
   if dryRun then
      return null
   end
   -- local args = { "-unit", tostring(unit.id),
   --                "-skill", skillName,
   --                "-mode", "set",
   --                "-granularity", "level",
   --                "-value", tostring(level) }
   -- dfhack.run_script('modtools/skill-change', table.unpack(args))

   -- copied from 'modtools/skill-change' but removed debug prints
   local skillId = df.job_skill[skillName]
   local skill
   for _,skill_c in ipairs(unit.status.current_soul.skills) do
      if skill_c.id == skillName then
         skill = skill_c
      end
   end

   if not skill then
      skill = df.unit_skill:new()
      skill.id = skillId
      utils.insert_sorted(unit.status.current_soul.skills,skill, "id")
   end
   skill.rating = level
end

function giveWeapon(unit, itemName, material, quality, bodyPart)
   giveItem(unit, itemName, material, quality, bodyPart, "Weapon")
end

function giveArmor(unit, itemName, materialName, quality, bodyPart, leftOrRight)
   giveItem(unit, itemName, materialName, quality, bodyPart, "Worn", leftOrRight)
end

function giveQuiverWithArrows(unit, quiverMaterialName, boltMaterialName, quality)
   if dryRun then
      return null
   end
   local quiver = createItem(unit, "QUIVER:NONE", quiverMaterialName, quality)
   local bolt = createItem(unit, "AMMO:ITEM_AMMO_ARROWS", boltMaterialName, quality)
   bolt.stack_size = 30

   dfhack.items.moveToContainer(bolt, quiver)   
   equipItem(unit, quiver, "UB", "Worn")
end

function giveItem(unit, itemName, materialName, quality, bodyPartName, modeName, leftOrRight)
   local item = createItem(unit, itemName, materialName, quality, leftOrRight)

   if not equipItem(unit, item, bodyPartName, modeName) then
      print("Warning: cannot equip " .. itemName .. " to " .. bodyPartName
            .. " for unit " .. unit.id)
   end
end

function createItem(unit, itemName, materialName, quality, leftOrRight)
   if dryRun then
      return null
   end
   
   local itemType = dfhack.items.findType(itemName)
   if itemType == -1 then
      error("Invalid item: " .. itemName)
   end
   local itemSubtype = dfhack.items.findSubtype(itemName)

   local materialInfo = dfhack.matinfo.find(materialName)
   if not materialInfo then
      error("Invalid material: " .. materialName)
   end

   local itemId = dfhack.items.createItem(itemType, itemSubtype,
                                          materialInfo['type'], materialInfo.index, unit)
   local item = df.item.find(itemId)
   if leftOrRight then
      if leftOrRight == "left" then
         item:setGloveHandedness(2)
      elseif leftOrRight == "right" then
         item:setGloveHandedness(1)
      else
         error("Invalid leftOrRight: " .. leftOrRight)
      end
   end
   
   if type(quality) == "number" and quality >= 0 and quality <= 5 then
      item:setQuality(quality)
   end
   return item
end

function equipItem(unit, item, bodyPartName, modeName)
   if dryRun then
      return true
   end
   
   local bodyPart
   local creature_raw = df.global.world.raws.creatures.all[unit.race]
   local caste_raw = creature_raw.caste[unit.caste]
   local body_info = caste_raw.body_info
   for k,v in pairs(body_info.body_parts) do
      if v.token == bodyPartName then
         bodyPart = k
         break
      end
   end
   
   local mode = df.unit_inventory_item.T_mode[modeName]
   return dfhack.items.moveToInventory(item, unit, mode, bodyPart)
end

function getInvasionTile()
   local xMax, yMax, zMax = dfhack.maps.getTileSize()

   local edgeTiles = {}
   for x = 0, xMax - 1 do
      table.insert(edgeTiles, {x = x, y = 0})
      table.insert(edgeTiles, {x = x, y = yMax - 1})
   end
   for y = 0, yMax - 1 do
      table.insert(edgeTiles, { x = 0, y = y })
      table.insert(edgeTiles, { x = xMax - 1, y = y })
   end

   shuffle(edgeTiles)

   for _, xy in pairs(edgeTiles) do
      local z = getGroundZ(xy.x, xy.y)
      if z then
         return xy.x, xy.y, z
      end
   end
   
   return nil
end

function getGroundZ(x, y)
   local _, _, zlen = dfhack.maps.getTileSize()
   for z = zlen, 0, -1 do
      local tileType = dfhack.maps.getTileType(x, y, z)
      if tileType then
         local tileTypeName = df.tiletype[tileType]
         local tileFlags = dfhack.maps.getTileFlags(x, y, z)
         if tileTypeName ~= "OpenSpace" and not string.find(tileTypeName, "Tree")
            and not string.find(tileTypeName, "Brook")
         and tileFlags.biome > 0 and tileFlags.outside and tileFlags.flow_size == 0 then
            return z
         end
      end
   end
   return nil
end

function string.starts(String,Start)
   return string.sub(String,1,string.len(Start))==Start
end

function string.ends(String, End)
   if (string.len(End) > string.len(String)) then
      return false
   end
   return string.sub(String, String.len(String) - string.len(End) + 1, string.len(String))==End
end

function math.round(number)
   return math.floor(number + 0.5)
end

function pickRandom(picksAndScores)
   local total = 0
   local cursor = 0
   local random, pick, score
   for pick, score in pairs(picksAndScores) do
      total = total + score
   end
   random = math.random(0, total)
   for pick, score in pairs(picksAndScores) do
      cursor = cursor + score
      if cursor >= random then
         return pick
      end
   end
   error("code error")
end

function throwDice(sides, throws)
   sides = math.floor(sides)
   if sides == 1 then
      return 1
   end
   local total = 0
   for i = 1, throws do
      total = total + math.random(sides)
   end
   return math.floor(total / throws)
end

-- generate random number [0;1] in a normal distribution like plot
-- spread is [1;1000], the higher the less variance
-- center is the high point of distribution, 0.5 is in the middle
function getDistValue(center, spread)
   local total = 0
   for i = 1, spread do
      total = total + math.random()
   end
   value = total / spread + center - 0.5
   if value < 0 then
      value = 0
   end
   if value > 1 then
      value = 1
   end
   return value
end

function pickOrderedDist(elements, center, spread)
   local val = getDistValue(center, spread)
   local index = 1 + math.round(val * (#elements - 1))
   if index < 1 then index = 1 end
   if index > #elements then index = #elements end
   return elements[index]
end

function shuffle(tbl)
   size = #tbl
   for i = size, 1, -1 do
      local rand = math.random(size)
      tbl[i], tbl[rand] = tbl[rand], tbl[i]
   end
   return tbl
end

function getPersistenceKey(key)
   return "outsiderInvasion_" .. key
end
function getPersistence()
   local function get(key)
      local entry = dfhack.persistent.get(getPersistenceKey(key))
      if entry and entry.value ~= "" then
         return entry.value
      else
         return nil
      end
   end
   
   return {
      everyMonths = tonumber(get("everyMonths")),
      invasionType = get("invasionType"),
      difficulty = tonumber(get("difficulty")),
      nextInvasionTick = tonumber(get("nextInvasionTick"))
   }
end

function savePersistence(data)
   local function put(key, value)
      dfhack.persistent.save({key=getPersistenceKey(key), value=tostring(value)})
   end

   put("everyMonths", data.everyMonths)
   put("invasionType", data.invasionType or "")
   put("difficulty", data.difficulty)
   put("nextInvasionTick", data.nextInvasionTick)
end

function checkGameStarted()
   if not dfhack.isWorldLoaded () or not dfhack.isMapLoaded () then
      error("No fort loaded")
   end
end

function printStatus()
   local data = getPersistence()

   print("Run with argument -help to see usage")
   print("")
   
   print("Current fortress strength = " .. getFortressStrength(1.0))
   print("Current fortress max invasion = " .. getFortressMaxInvasionCap())

   if data.everyMonths then
      print("Sending an invasion every " .. data.everyMonths .. " months")
      print("Next invasion will happen on " .. getDate(data.nextInvasionTick))
      if data.invasionType then
         print("  invasion-type = " .. data.invasionType)
      end
      if data.difficulty then
         print("  difficulty = " .. data.difficulty)
      end
   else
      print("Not currently automatically sending invasions")
   end
end

local ticksInDay = 1200
local ticksInMonth = ticksInDay * 28
local ticksInYear = ticksInMonth * 12

function getTickAfterMonths(months)
   return df.global.cur_year * ticksInYear + df.global.cur_year_tick + ticksInMonth * months
end

function getTick()
   return df.global.cur_year * ticksInYear + df.global.cur_year_tick
end

function getDate(tick)
   local curYear = math.floor(tick / ticksInYear)
   local curYearTick = tick % ticksInYear
   local julian_day = math.floor(curYearTick / ticksInDay) + 1
   local month = math.floor(julian_day / 28) + 1
   local day = julian_day % 28
   return string.format('%d-%02d-%02d', df.global.cur_year, month, day)
end

function setEveryMonths(args)
   local data = getPersistence()
   local everyMonths = tonumber(args["every-months"])
   if everyMonths == data.everyMonths then
      -- If setting same everyMonths then do nothing
      -- This allows you to set 'outsider-invasion -every-months 10' in dfhack.init
      return
   end
   if everyMonths == 0 then
      data.everyMonths = nil
      data.nextInvasionTick = nil
      data.invasionType = nil
      data.difficulty = nil
   else
      data.everyMonths = everyMonths
      data.nextInvasionTick = getTickAfterMonths(everyMonths)
      data.invasionType = args["invasion-type"]
      data.difficulty = args["difficulty"]
   end
   savePersistence(data)

   doEnable()
end

function makeOldInvadersFlee()
   local curTick = getTick()
   local oldTick = curTick - ticksInMonth
   
   for _, unit in pairs(df.global.world.units.all) do
      local isSpawnedInvader = unit.flags1.active_invader and unit.invasion_id == -1
      if isSpawnedInvader then
         if not spawnedUnitsDates[unit.id] then
            -- if not recorded its arrival date, do it now
            spawnedUnitsDates[unit.id] = curTick
         else
            local spawnedUnitDate = spawnedUnitsDates[unit.id]
            -- if invader is too old, then make it flee the map
            if spawnedUnitsDates[unit.id] < oldTick then
               unit.flags1.active_invader = false
               unit.flags1.invader_origin = false
               unit.flags1.invades = false
               unit.flags1.hidden_ambusher = false
            end
         end
      end
   end
end

function eventLoop()
   if dfhack.isWorldLoaded () and dfhack.isMapLoaded () then
      local data = getPersistence()
      
      makeOldInvadersFlee()
      
      if data.nextInvasionTick and getTick() >= data.nextInvasionTick then
         invasion({
               ["invasion-type"] = data.invasionType,
               ["difficulty"] = data.difficulty
         })
         
         data.nextInvasionTick = getTickAfterMonths(data.everyMonths)
         savePersistence(data)
      end
   end
   setEventLoop()
end

function setEventLoop()
   dfhack.timeout_active(eventLoopTimeoutId, nil)
   eventLoopTimeoutId = dfhack.timeout(1, "days", eventLoop)
end

dfhack.onStateChange.outsiderInvasion = function(code)
   if code == SC_MAP_LOADED then
      if enabled then
         setEventLoop()
      else
         if eventLoopTimeoutId then
            dfhack.timeout_active(eventLoopTimeoutId, nil)
         end
      end
   end
end

function doEnable()
   if not enabled then
      enabled = true
      if dfhack.isMapLoaded() then
         dfhack.onStateChange.outsiderInvasion(SC_MAP_LOADED)
      end
   end
end

local invasionTypes = {
   {
      name = "goblins",
      func = goblinInvasion
   },
   {
      name = "elves",
      func = elfInvasion
   },
   {
      name = "semimegabeasts",
      func = semiMegaBeastInvasion
   }
}

function invasion(options)
   options = options or {}
   local difficulty = options.difficulty and tonumber(options.difficulty) or 1.0
   local strength = options.strength and tonumber(options.strength) or getFortressStrength(difficulty)
   local cap = options.cap and tonumber(options.cap) or getFortressMaxInvasionCap()
   dryRun = options["dry-run"] and true or false
   logTrace = logTrace or dryRun
   if not options["invasion-type"] then
      options["invasion-type"] = "goblins"
   end
   local invasionType = null
   if options["invasion-type"] then
      if options["invasion-type"] == "random" then
         invasionType = invasionTypes[math.random(#invasionTypes)]
      else
         for _,v in pairs(invasionTypes) do
            if v.name == options["invasion-type"] then
               invasionType = v
            end
         end
         if not invasionType then
            error("Invalid invasion-type: " .. options["invasion-type"])
         end
      end
   end
   local arenaSide = options["arena-side"] and tonumber(options["arena-side"]) or 0

   local x, y, z
   if dfhack.world.isArena() then
      x = df.global.cursor.x
      y = df.global.cursor.y
      z = df.global.cursor.z
      if x < 0 or y < 0 or z < 0 then
         error("Cursor at invalid position")
      end
      if not options.strength then
         error("Must define -strength argument when in arena mode")
      end
   else
      x, y, z = getInvasionTile();
      if not x then
         error("Could not find valid edge tile to invade from")
      end
   end
   
   if not dryRun then
      df.global.pause_state = true
      dlg.showMessage("Invasion!",
                      "You are being invaded by outsider " .. invasionType.name .. ".\n"..
                         "Strength=" .. strength,
                      COLOR_RED)
      print("outsider-invasion: Sending an invasion! type="
               .. invasionType.name .. ", strength=" .. strength)
   end

   invasionType.func(x, y, z, strength, cap, arenaSide)
end

function run(rawArgs)
   if not dfhack.isWorldLoaded () or not dfhack.isMapLoaded () then
      print("Error, not started playing yet")
      return
   end

   validArgs = utils.invert({
         "help",
         "now",
         "invasion-type",
         "difficulty",
         "strength",
         "cap",
         "dry-run",
         "arena-side",
         "every-months"
   })

   local args = utils.processArgs(rawArgs, validArgs)

   if args.help then
      print(usage)
      return
   end

   if args.now then
      checkGameStarted()
      invasion(args)
   elseif args["every-months"] then
      checkGameStarted()
      setEveryMonths(args)
   else
      checkGameStarted()
      printStatus()
   end
end

doEnable()

run({...})
