-- Skill → stat-dependency table for discworld-vitals.
--
-- Every skill's bonus multiplicator M depends on five stat "slots", and which
-- stats fill those slots is fixed per skill. This table is the mapping, as a
-- compact 5-letter code per skill path (C/D/I/S/W = Constitution / Dexterity /
-- Intelligence / Strength / Wisdom, with repeats — e.g. people.teaching is
-- "IIIWW" = Int×3, Wis×2).
--
-- WHEN THIS IS NEEDED: src/bonus.lua can derive M empirically from any skill
-- the character already has a (level, bonus) for — that path needs no table.
-- This table is for the two cases empirical M can't cover: skills at zero
-- levels (no bonus to back M out of), and stat "what-if" planning (which
-- skills change, and by how much, when you raise a stat).
--
-- Provenance: ported verbatim from tt_dw scripts/char/data.tin (which in turn
-- tracks http://bonuses.irreducible.org). 251 entries — both leaf skills and
-- their category nodes. Per the source's own caveat these are observed, not
-- guaranteed-exact; the empirical path is authoritative when available.
--
-- Pure Lua, no host-API dependencies — unit-tested under tests/skill_data_test.lua.

local bonus = require("bonus")

local M = {}

-- Letter → stat name, matching the keys src/stats_parser.lua emits.
M.STAT_LETTERS = {
  C = "constitution",
  D = "dexterity",
  I = "intelligence",
  S = "strength",
  W = "wisdom",
}

-- [skill path] = 5-letter stat code.
M.STAT_CODES = {
  ["adventuring"] = "DDISS",
  ["adventuring.acrobatics"] = "CDDSS",
  ["adventuring.acrobatics.balancing"] = "CDDSS",
  ["adventuring.acrobatics.tumbling"] = "CDDSS",
  ["adventuring.acrobatics.vaulting"] = "CDDSS",
  ["adventuring.direction"] = "DDIIW",
  ["adventuring.evaluating"] = "IIIIW",
  ["adventuring.evaluating.armour"] = "IIIIW",
  ["adventuring.evaluating.weapons"] = "IIIIW",
  ["adventuring.health"] = "CCCCS",
  ["adventuring.movement"] = "CCDDS",
  ["adventuring.movement.climbing"] = "CCDDS",
  ["adventuring.movement.climbing.rock"] = "CCDDS",
  ["adventuring.movement.climbing.rope"] = "CCDDS",
  ["adventuring.movement.climbing.tree"] = "CCDDS",
  ["adventuring.movement.following"] = "CCDDS",
  ["adventuring.movement.following.evade"] = "CCDDS",
  ["adventuring.movement.following.pursuit"] = "CCDDS",
  ["adventuring.movement.riding"] = "CCDDS",
  ["adventuring.movement.riding.camel"] = "CCDDS",
  ["adventuring.movement.riding.horse"] = "CCDDS",
  ["adventuring.movement.sailing"] = "CCDDS",
  ["adventuring.movement.swimming"] = "CCDDS",
  ["adventuring.perception"] = "IIWWW",
  ["adventuring.points"] = "CDISW",
  ["covert"] = "DDDII",
  ["covert.casing"] = "DIIWW",
  ["covert.casing.person"] = "DIIWW",
  ["covert.casing.place"] = "DIIWW",
  ["covert.hiding"] = "DDIIS",
  ["covert.hiding.object"] = "DDIIS",
  ["covert.hiding.person"] = "DDIIS",
  ["covert.items"] = "DIIII",
  ["covert.items.poisons"] = "DIIII",
  ["covert.items.traps"] = "DIIII",
  ["covert.items.weapons"] = "DIIII",
  ["covert.lockpick"] = "DDDDI",
  ["covert.lockpick.doors"] = "DDDDI",
  ["covert.lockpick.safes"] = "DDDDI",
  ["covert.lockpick.traps"] = "DDDDI",
  ["covert.manipulation"] = "DDISS",
  ["covert.manipulation.palming"] = "DDISS",
  ["covert.manipulation.passing"] = "DDISS",
  ["covert.manipulation.sleight-of-hand"] = "DDISS",
  ["covert.manipulation.stealing"] = "DDISS",
  ["covert.points"] = "DDIIC",
  ["covert.stealth"] = "DDDIS",
  ["covert.stealth.inside"] = "DDDIS",
  ["covert.stealth.outside"] = "DDDIS",
  ["covert.stealth.underwater"] = "DDDIS",
  ["crafts"] = "DDIIW",
  ["crafts.arts"] = "DIIII",
  ["crafts.arts.calligraphy"] = "DIIII",
  ["crafts.arts.design"] = "DIIII",
  ["crafts.arts.drawing"] = "DIIII",
  ["crafts.arts.painting"] = "DIIII",
  ["crafts.arts.printing"] = "DIIII",
  ["crafts.arts.sculpture"] = "DIIII",
  ["crafts.arts.theatre"] = "DIIII",
  ["crafts.carpentry"] = "DDIIS",
  ["crafts.carpentry.coopering"] = "DDIIS",
  ["crafts.carpentry.furniture"] = "DDIIS",
  ["crafts.carpentry.turning"] = "DDIIS",
  ["crafts.carpentry.whittling"] = "DDIIS",
  ["crafts.culinary"] = "DDIII",
  ["crafts.culinary.baking"] = "DDIII",
  ["crafts.culinary.brewing"] = "DDIII",
  ["crafts.culinary.butchering"] = "DDIII",
  ["crafts.culinary.cooking"] = "DDIII",
  ["crafts.culinary.distilling"] = "DDIII",
  ["crafts.culinary.preserving"] = "DDIII",
  ["crafts.hunting"] = "DDIII",
  ["crafts.hunting.fishing"] = "DDIII",
  ["crafts.hunting.foraging"] = "DDIII",
  ["crafts.hunting.tracking"] = "DDIII",
  ["crafts.hunting.trapping"] = "DDIII",
  ["crafts.husbandry"] = "IIIWW",
  ["crafts.husbandry.animal"] = "IIIWW",
  ["crafts.husbandry.animal.breeding"] = "IIIWW",
  ["crafts.husbandry.animal.grooming"] = "IIIWW",
  ["crafts.husbandry.animal.slaughtering"] = "IIIWW",
  ["crafts.husbandry.plant"] = "IIIWW",
  ["crafts.husbandry.plant.edible"] = "IIIWW",
  ["crafts.husbandry.plant.herbal"] = "IIIWW",
  ["crafts.husbandry.plant.milling"] = "IIIWW",
  ["crafts.husbandry.plant.tree"] = "IIIWW",
  ["crafts.materials"] = "DDIIS",
  ["crafts.materials.dyeing"] = "DDIIS",
  ["crafts.materials.leatherwork"] = "DDIIS",
  ["crafts.materials.needlework"] = "DDIIS",
  ["crafts.materials.spinning"] = "DDIIS",
  ["crafts.materials.tanning"] = "DDIIS",
  ["crafts.materials.weaving"] = "DDIIS",
  ["crafts.medicine"] = "DIIWW",
  ["crafts.medicine.diagnosis"] = "DIIWW",
  ["crafts.medicine.firstaid"] = "DIIWW",
  ["crafts.medicine.treatment"] = "DIIWW",
  ["crafts.medicine.treatment.disease"] = "DIIWW",
  ["crafts.medicine.treatment.injury"] = "DIIWW",
  ["crafts.medicine.treatment.poison"] = "DIIWW",
  ["crafts.mining"] = "DIISS",
  ["crafts.mining.gem"] = "DIISS",
  ["crafts.mining.mineral"] = "DIISS",
  ["crafts.mining.ore"] = "DIISS",
  ["crafts.mining.ore.panning"] = "DIISS",
  ["crafts.music"] = "DIIII",
  ["crafts.music.instruments"] = "DIIII",
  ["crafts.music.instruments.keyboard"] = "DIIII",
  ["crafts.music.instruments.percussion"] = "DIIII",
  ["crafts.music.instruments.stringed"] = "DIIII",
  ["crafts.music.instruments.vocal"] = "DIIII",
  ["crafts.music.instruments.wind"] = "DIIII",
  ["crafts.music.performance"] = "DIIII",
  ["crafts.music.special"] = "DIIII",
  ["crafts.music.theory"] = "DIIII",
  ["crafts.points"] = "DDIIW",
  ["crafts.pottery"] = "DDDII",
  ["crafts.pottery.firing"] = "DDDII",
  ["crafts.pottery.forming"] = "DDDII",
  ["crafts.pottery.forming.shaping"] = "DDDII",
  ["crafts.pottery.forming.throwing"] = "DDDII",
  ["crafts.pottery.glazing"] = "DDDII",
  ["crafts.pottery.staining"] = "DDDII",
  ["crafts.smithing"] = "DDIIS",
  ["crafts.smithing.black"] = "DDIIS",
  ["crafts.smithing.black.armour"] = "DDIIS",
  ["crafts.smithing.black.tools"] = "DDIIS",
  ["crafts.smithing.black.weapons"] = "DDIIS",
  ["crafts.smithing.gem"] = "DDIIS",
  ["crafts.smithing.gem.cutting"] = "DDIIS",
  ["crafts.smithing.gem.polishing"] = "DDIIS",
  ["crafts.smithing.gem.setting"] = "DDIIS",
  ["crafts.smithing.gold"] = "DDIIS",
  ["crafts.smithing.locks"] = "DDIIS",
  ["crafts.smithing.silver"] = "DDIIS",
  ["faith"] = "ISWWW",
  ["faith.items"] = "IIDWW",
  ["faith.items.rod"] = "IIDWW",
  ["faith.items.scroll"] = "IIDWW",
  ["faith.points"] = "IICWW",
  ["faith.rituals"] = "ISWWW",
  ["faith.rituals.curing"] = "ICCWW",
  ["faith.rituals.curing.self"] = "ICCWW",
  ["faith.rituals.curing.target"] = "ICCWW",
  ["faith.rituals.defensive"] = "IDDWW",
  ["faith.rituals.defensive.area"] = "IDDWW",
  ["faith.rituals.defensive.self"] = "IDDWW",
  ["faith.rituals.defensive.target"] = "IDDWW",
  ["faith.rituals.misc"] = "IIWWW",
  ["faith.rituals.misc.area"] = "IIWWW",
  ["faith.rituals.misc.self"] = "IIWWW",
  ["faith.rituals.misc.target"] = "IIWWW",
  ["faith.rituals.offensive"] = "ISSWW",
  ["faith.rituals.offensive.area"] = "ISSWW",
  ["faith.rituals.offensive.target"] = "ISSWW",
  ["faith.rituals.special"] = "ISWWW",
  ["fighting"] = "CDDSS",
  ["fighting.defence"] = "DDSSW",
  ["fighting.defence.blocking"] = "DDSSW",
  ["fighting.defence.dodging"] = "DDDDW",
  ["fighting.defence.parrying"] = "DDDSW",
  ["fighting.melee"] = "CDDSS",
  ["fighting.melee.axe"] = "CDSSS",
  ["fighting.melee.dagger"] = "DDDDS",
  ["fighting.melee.flail"] = "CDDSS",
  ["fighting.melee.heavy-sword"] = "CDSSS",
  ["fighting.melee.mace"] = "CCDSS",
  ["fighting.melee.misc"] = "CDDSS",
  ["fighting.melee.polearm"] = "CCSSS",
  ["fighting.melee.sword"] = "DDDSS",
  ["fighting.points"] = "DSSCC",
  ["fighting.range"] = "DDDSS",
  ["fighting.range.fired"] = "DDDDS",
  ["fighting.range.thrown"] = "DDDSS",
  ["fighting.special"] = "CDSII",
  ["fighting.special.mounted"] = "CCDDW",
  ["fighting.special.tactics"] = "WWIII",
  ["fighting.special.unarmed"] = "DDIII",
  ["fighting.special.weapon"] = "SDIII",
  ["fighting.unarmed"] = "DDSSW",
  ["fighting.unarmed.grappling"] = "DDSSW",
  ["fighting.unarmed.striking"] = "DDSWW",
  ["magic"] = "IIIDW",
  ["magic.items"] = "IIDWW",
  ["magic.items.held"] = "IIDWW",
  ["magic.items.held.broom"] = "IIDWW",
  ["magic.items.held.rod"] = "IIDWW",
  ["magic.items.held.staff"] = "IIDWW",
  ["magic.items.held.wand"] = "IIDWW",
  ["magic.items.scroll"] = "IIDWW",
  ["magic.items.talisman"] = "IIDWW",
  ["magic.items.worn"] = "IIDWW",
  ["magic.items.worn.amulet"] = "IIDWW",
  ["magic.items.worn.ring"] = "IIDWW",
  ["magic.methods"] = "IIIDW",
  ["magic.methods.elemental"] = "IICCC",
  ["magic.methods.elemental.air"] = "IICCC",
  ["magic.methods.elemental.earth"] = "IICCC",
  ["magic.methods.elemental.fire"] = "IICCC",
  ["magic.methods.elemental.water"] = "IICCC",
  ["magic.methods.mental"] = "IIIII",
  ["magic.methods.mental.animating"] = "IIIII",
  ["magic.methods.mental.channeling"] = "IIIII",
  ["magic.methods.mental.charming"] = "IIIII",
  ["magic.methods.mental.convoking"] = "IIIII",
  ["magic.methods.mental.cursing"] = "IIIII",
  ["magic.methods.physical"] = "IIDDD",
  ["magic.methods.physical.binding"] = "IIDDD",
  ["magic.methods.physical.brewing"] = "IIDDD",
  ["magic.methods.physical.chanting"] = "IIDDD",
  ["magic.methods.physical.dancing"] = "IIDDD",
  ["magic.methods.physical.enchanting"] = "IIDDD",
  ["magic.methods.physical.evoking"] = "IIDDD",
  ["magic.methods.physical.healing"] = "IIDDD",
  ["magic.methods.physical.scrying"] = "IIDDD",
  ["magic.methods.spiritual"] = "IIWWW",
  ["magic.methods.spiritual.abjuring"] = "IIWWW",
  ["magic.methods.spiritual.banishing"] = "IIWWW",
  ["magic.methods.spiritual.conjuring"] = "IIWWW",
  ["magic.methods.spiritual.divining"] = "IIWWW",
  ["magic.methods.spiritual.summoning"] = "IIWWW",
  ["magic.points"] = "IISWW",
  ["magic.spells"] = "IIDWW",
  ["magic.spells.defensive"] = "WCCII",
  ["magic.spells.misc"] = "WDDII",
  ["magic.spells.offensive"] = "WSSII",
  ["magic.spells.special"] = "WWWII",
  ["people"] = "DDISS",
  ["people.culture"] = "IIIWW",
  ["people.culture.agatean"] = "IIIWW",
  ["people.culture.ankh-morporkian"] = "IIIWW",
  ["people.culture.genuan"] = "IIIWW",
  ["people.culture.klatchian"] = "IIIWW",
  ["people.culture.lancrastian"] = "IIIWW",
  ["people.points"] = "CDISW",
  ["people.teaching"] = "IIIWW",
  ["people.teaching.adventuring"] = "CDISW",
  ["people.teaching.covert"] = "DDIIC",
  ["people.teaching.crafts"] = "DDIIW",
  ["people.teaching.faith"] = "IICWW",
  ["people.teaching.fighting"] = "CDDSS",
  ["people.teaching.magic"] = "IISWW",
  ["people.teaching.people"] = "CDISW",
  ["people.trading"] = "IIIIW",
  ["people.trading.buying"] = "IIIIW",
  ["people.trading.selling"] = "IIIIW",
  ["people.trading.valueing"] = "IIIIW",
  ["people.trading.valueing.armour"] = "IIIIW",
  ["people.trading.valueing.gems"] = "IIIIW",
  ["people.trading.valueing.jewellery"] = "IIIIW",
  ["people.trading.valueing.weapons"] = "IIIIW",
}

-- The relevant teaching skill for a skill is people.teaching.<top branch>,
-- e.g. magic.spells.offensive → people.teaching.magic. Returns nil for an
-- unrecognised path (no dot-delimited root).
function M.teaching_skill_for(path)
  if type(path) ~= "string" then return nil end
  local root = path:match("^([^.]+)")
  if not root then return nil end
  return "people.teaching." .. root
end

-- True if we have a stat code for this skill path.
function M.is_known(path)
  return M.STAT_CODES[path] ~= nil
end

-- Expand a skill's stat code into the array of five stat VALUES, pulled from
-- a stats table { constitution=, dexterity=, intelligence=, strength=,
-- wisdom= } (the shape src/stats_parser.lua produces). Returns nil if the
-- path is unknown or any required stat is missing.
function M.stat_values_for(path, stats)
  local code = M.STAT_CODES[path]
  if not code or type(stats) ~= "table" then return nil end
  local values = {}
  for i = 1, #code do
    local stat_name = M.STAT_LETTERS[code:sub(i, i)]
    local v = stat_name and stats[stat_name]
    if type(v) ~= "number" then return nil end
    values[#values + 1] = v
  end
  return values
end

-- Sibling map for abbreviate(), built lazily from STAT_CODES:
--   _children[parent path] = { [child segment] = true }
-- ("" is the parent of the seven roots.)
local _children

local function build_children()
  _children = {}
  for path in pairs(M.STAT_CODES) do
    local prefix = ""
    for seg in path:gmatch("[^.]+") do
      local bucket = _children[prefix]
      if not bucket then bucket = {}; _children[prefix] = bucket end
      bucket[seg] = true
      prefix = (prefix == "") and seg or (prefix .. "." .. seg)
    end
  end
end

-- Shortest prefix of `name` (at least `floor` chars) that no other sibling
-- shares — i.e. the briefest unambiguous abbreviation of this node.
local function min_unique_prefix(name, siblings, floor)
  local len = math.min(math.max(floor, 1), #name)
  while len < #name do
    local pre, clash = name:sub(1, len), false
    for s in pairs(siblings) do
      if s ~= name and s:sub(1, len) == pre then clash = true; break end
    end
    if not clash then break end
    len = len + 1
  end
  return name:sub(1, len)
end

-- Abbreviate a dotted skill path to its briefest still-unambiguous form,
-- using two letters per node and extending only the nodes whose two-letter
-- prefix collides with a sibling — e.g. magic.spells.defensive → "ma.sp.de",
-- magic.methods.mental.channeling → "ma.me.me.chan". The result is globally
-- unique across the skill tree and resolves back via planner.resolve_skill.
-- Unknown branches (not in the tree) fall back to a flat two-letter prefix.
function M.abbreviate(path)
  if type(path) ~= "string" then return path end
  if not _children then build_children() end
  local out, prefix = {}, ""
  for seg in path:gmatch("[^.]+") do
    local siblings = _children[prefix]
    out[#out + 1] = siblings and min_unique_prefix(seg, siblings, 2) or seg:sub(1, 2)
    prefix = (prefix == "") and seg or (prefix .. "." .. seg)
  end
  return table.concat(out, ".")
end

-- Compute the multiplicator M for a skill from a stats table, via the
-- stat-based formula in src/bonus.lua. Returns nil if the path is unknown,
-- stats are missing, or M is undefined. This is the "from stats" counterpart
-- to bonus.derive_multiplicator (the "from observed bonus" path).
function M.multiplicator_for(path, stats)
  local values = M.stat_values_for(path, stats)
  if not values then return nil end
  return bonus.stat_multiplicator(values)
end

return M
