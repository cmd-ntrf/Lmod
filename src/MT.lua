require("strict")
_ModuleTable_      = ""
local DfltModPath  = DfltModPath
local Master       = Master
local ModulePath   = ModulePath
local Purge        = Purge
local assert       = assert
local concatTbl    = table.concat
local expert       = expert
local getenv       = os.getenv
local ignoreT      = { ['.'] =1, ['..'] = 1, CVS=1, ['.git'] = 1, ['.svn']=1,
                       ['.hg']= 1, ['.bzr'] = 1,}
local io           = io
local ipairs       = ipairs
local loadstring   = loadstring
local max          = math.max
local next         = next
local os           = os
local pairs        = pairs
local prtErr       = prtErr
local setmetatable = setmetatable
local string       = string
local systemG      = _G
local tostring     = tostring
local type         = type
local unpack       = unpack
local varTbl       = varTbl

require("string_split")
require("fileOps")
require("serializeTbl")

local Var          = require('Var')
local lfs          = require('lfs')
local pathJoin     = pathJoin
local Dbg          = require('Dbg')
local ColumnTable  = require('ColumnTable')
local posix        = require("posix")


--module("MT")
local M = {}

function M.name(self)
   return '_ModuleTable_'
end

s_loadOrder = 0
s_mt = nil

local function build_locationTbl(tbl, pathA)
   local dbg = Dbg:dbg()
   for _,path in ipairs(pathA)  do
      local attr = lfs.attributes(path)
      if ( attr and attr.mode == "directory") then
         for file in lfs.dir(path) do
            local f = pathJoin(path,file)
            local readable = posix.access(f,"r")
            if (readable and not ignoreT[file]) then
               local a   = tbl[file] or {}
               file      = file:gsub("%.lua$","")
               a[#a+1]   = {file = f, mpath = path }
               tbl[file] = a
            end
         end
      end
   end
end

local function columnList(stream, msg, a)
   local t = {}
   table.sort(a)
   for i = 1, #a do
      t[#t + 1] = '  ' .. i .. ') ' .. tostring(a[i])
   end
   stream:write(msg)
   local ct = ColumnTable:new{tbl=t}
   stream:write(ct:build_tbl(),"\n")
end


local function new(self, s)
   local dbg  = Dbg:dbg()
   dbg.start("MT:new()")
   local o            = {}

   o.c_rebuildTime    = false
   o.mT               = {}
   o.version          = 2
   o.family           = {}
   o.mpathA           = {}
   o.baseMpathA       = {}
   o._same            = true
   o._MPATH           = ""
   o._locationTbl     = {}

   o._changePATH      = false
   o._changePATHCount = 0

   setmetatable(o,self)
   self.__index = self

   local active, total

   if (not s) then
      local v             = getenv(ModulePath)
      varTbl[DfltModPath] = Var:new(DfltModPath, v)
      o:buildBaseMpathA(v)
      dbg.print("Initializing ", DfltModPath, ":", v, "\n")
   else
      assert(loadstring(s))()
      local _ModuleTable_ = systemG._ModuleTable_

      if (_ModuleTable_.version == 1) then
         s_loadOrder = o:convertMT(_ModuleTable_)
      else
         for k,v in pairs(_ModuleTable_) do
            o[k] = v
         end
         local icount = 0
         for k in pairs(o.mT) do
            icount = icount + 1
         end
         s_loadOrder = icount
      end
      o._MPATH = concatTbl(o.mpathA,":")
      varTbl[DfltModPath] = Var:new(DfltModPath, concatTbl(o.baseMpathA,":"))
   end
   o.inactive         = {}

   dbg.fini()
   return o
end

function M.convertMT(self, v1)
   local active = v1.active
   local a      = active.Loaded
   local sz     = #a
   for i = 1, sz do
      local sn    = a[i]
      local hash  = nil
      if (active.hash and active.hash[i]) then
         hash = active.hash[i]
      end
      
      local t     = { fn = active.FN[i], modFullName = active.fullModName[i],
                      default = active.default[i], modName = sn,
                      mType   = active.mType[i], hash = hash,
      }
      self:add(t,"active")
   end

   local aa    = {}
   local total = v1.total
   a           = total.Loaded
   for i = 1, #a do
      local sn = a[i]
      if (not self:have(sn,"active")) then
         local t = { modFullName = total.fullModName[i], modName = sn }
         self:add(t,"inactive")
         aa[#aa+1] = sn
      end
   end
   
   self.mpathA     = v1.mpathA
   self.baseMpathA = v1.baseMpathA
   self.inactive   = aa

   return sz   -- Return the new loadOrder number.
end
   


function M.getRebuildTime(self)
   return self.c_rebuildTime
end

function M.setRebuildTime(self,value)
   self.c_rebuildTime = value
end


local function setupMPATH(self,mpath)
   self._same = self:sameMPATH(mpath)
   if (not self._same) then
      self:buildMpathA(mpath)
   end
   build_locationTbl(self._locationTbl,self.mpathA)
end

function M.mt(self)
   if (s_mt == nil) then
      local dbg  = Dbg:dbg()
      dbg.start("mt()")
      local shell        = systemG.Master:master().shell
      s_mt               = new(self, shell:getMT())
      varTbl[ModulePath] = Var:new(ModulePath)
      setupMPATH(s_mt, varTbl[ModulePath]:expand())
      if (not s_mt._same) then
         s_mt:reloadAllModules()
      end
      dbg.fini()
   end
   return s_mt
end

function M.getMTfromFile(self,fn)
   local dbg  = Dbg:dbg()
   dbg.start("mt:getMTfromFile(",fn,")")
   local f = io.open(fn,"r")
   if (not f) then
      io.stdout:write("false\n")
      os.exit(1)
   end
   local s = f:read("*all")
   f:close()

   -----------------------------------------------
   -- Initialize MT with file: fn
   -- Save module name in hash table "t"
   -- with Hash Sum as value

   local l_mt   = new(self, s)
   local mpath  = l_mt._MPATH
   local t      = {}
   local a      = {}  -- list of "worker-bee" modules
   local m      = {}  -- list of "manager"    modules

   local active = l_mt:list("fullName","active")

   ---------------------------------------------
   -- If any module specified in the "default" file
   -- is a default then use the short name.  This way
   -- getting the modules from the "getdefault" specified
   -- file will work even when the defaults have changed.

   for i = 1,#active do
      local name 
      local full      = active[i]
      local short     = l_mt:short(full)
      local isDefault = l_mt:default(short)
      if (isDefault) then
         name         = short
      else
         name         = full
      end
      t[name]     = l_mt:getHash(name)
      local mType = l_mt:mType(name)
      if (mType == "w") then
         a[#a+1] = name
      else
         m[#m+1] = name
      end
      dbg.print("full: ",full," short: ",short," name: ",name," isDefault: ",tostring(isDefault),
                " mType: ", mType, "\n")
   end
   
   varTbl[ModulePath] = Var:new(ModulePath,mpath)
   dbg.print("(1) varTbl[ModulePath]:expand(): ",varTbl[ModulePath]:expand(),"\n")
   Purge()
   mpath = varTbl[ModulePath]:expand()
   dbg.print("(2) varTbl[ModulePath]:expand(): ",mpath,"\n")

   -----------------------------------------------------------
   -- Clear MT and load modules from saved modules stored in
   -- "t" from above.
   local baseMPATH = concatTbl(self.baseMpathA,":")
   s_mt = new(self,nil)
   posix.setenv(self:name(),"",true)
   setupMPATH(s_mt, mpath)
   s_mt:buildBaseMpathA(baseMPATH)
   varTbl[DfltModPath] = Var:new(DfltModPath,baseMPATH)

   dbg.print("(3) varTbl[ModulePath]:expand(): ",varTbl[ModulePath]:expand(),"\n")
   local mcp_old = mcp
   mcp           = MCP
   local loadA   = mcp:load(unpack(a))
   mcp           = mcp_old

   local master = systemG.Master:master()

   master.fakeload(unpack(m))

   local aa = {}
   for i = 1,#loadA do
      if (not loadA[i]) then
         aa[#aa+1] = a[i]
         t[a[i]]   = nil   -- do not need to check hash for a non-existant module
      end
   end

   if (#aa > 0) then
      dbg.warning("The following modules were not loaded: ", concatTbl(aa," "),"\n")
   end

   aa = {}
   s_mt:setHashSum()
   for k,v  in pairs(t) do
      if(v ~= s_mt:getHash(k)) then
         aa[#aa + 1] = k
      end
   end

   
   if (#aa > 0) then
      dbg.warning("The following modules have changed: ", concatTbl(aa," "),"\n")
      dbg.warning("Please re-create this collection\n")
   end


   s_mt:hideHash()

   local n = "__LMOD_DEFAULT_MODULES_LOADED__"
   varTbl[n] = Var:new(n)
   varTbl[n]:set("1")
   dbg.print("baseMpathA: ",concatTbl(self.baseMpathA,":"),"\n")

   dbg.fini()
end
   
function M.changePATH(self)
   if (not self._changePATH) then
      assert(self._changePATHCount == 0)
      self._changePATHCount = self._changePATHCount + 1
   end
   self._changePATH = true
end

function M.beginOP(self)
   if (self._changePATH == true) then
      self._changePATHCount = self._changePATHCount + 1
   end
end

function M.endOP(self)
   if (self._changePATH == true) then
      self._changePATHCount = max(self._changePATHCount - 1, 0)
   end
end

function M.safeToCheckZombies(self)
   local result = self._changePATHCount == 0 and self._changePATH
   local s      = "nil"
   if (result) then  s = "true" end
   if (self._changePATHCount == 0) then
      self._changePATH = false
   end
   return result
end


function M.setfamily(self,familyNm,mName)
   local results = self.family[familyNm]
   self.family[familyNm] = mName
   local n = "LMOD_FAMILY_" .. familyNm:upper()
   MCP:setenv(n, mName)
   n = "TACC_FAMILY_" .. familyNm:upper()
   MCP:setenv(n, mName)
   return results
end

function M.unsetfamily(self,familyNm)
   local n = "LMOD_FAMILY_" .. familyNm:upper()
   MCP:unsetenv(n, "")
   n = "TACC_FAMILY_" .. familyNm:upper()
   MCP:unsetenv(n, "")
   self.family[familyNm] = nil
end

function M.getfamily(self,familyNm)
   if (familyNm == nil) then
      return self.family
   end
   return self.family[familyNm]
end


function M.locationTbl(self, fn)
   return self._locationTbl[fn]
end

function M.sameMPATH(self, mpath)
   return self._MPATH == mpath
end

function M.module_pathA(self)
   return self.mpathA
end

function M.buildMpathA(self, mpath)
   local mpathA = {}
   for path in mpath:split(":") do
      mpathA[#mpathA + 1] = path
   end
   self.mpathA = mpathA
   self._MPATH = concatTbl(mpathA,":")
end

function M.buildBaseMpathA(self, mpath)
   local mpathA = {}
   mpath = mpath or ""
   for path in mpath:split(":") do
      mpathA[#mpathA + 1] = path
   end
   self.baseMpathA = mpathA
end


function M.getBaseMPATH(self)
   return concatTbl(self.baseMpathA,":")
end

function M.reEvalModulePath(self)
   self:buildMpathA(varTbl[ModulePath]:expand())
   self._locationTbl = {}
   build_locationTbl(self._locationTbl, self.mpathA)
end

function M.reloadAllModules(self)
   local dbg    = Dbg:dbg()
   local master = systemG.Master:master()
   local count  = 0
   local ncount = 5

   local changed = false
   local done    = false
   while (not done) do
      local same  = master:reloadAll()
      if (not same) then
         changed = true
      end
      count       = count + 1
      if (count > ncount) then
         LmodError("ReLoading more than ", ncount, " times-> exiting\n")
      end
      done = self:sameMPATH(varTbl[ModulePath]:expand())
   end

   local safe = master:safeToUpdate()
   if (not safe and changed) then
      LmodError("MODULEPATH has changed: run \"module update\" to repair\n")
   end
   return not changed
end


------------------------------------------------------------
-- Pass-Thru function modules in the Active list

function shortName(moduleName)
   return moduleName:gsub("([^/]+)/.*","%1")
end

function M.add(self, t, status)
   local dbg   = Dbg:dbg()
   dbg.start("MT:add(t,",status,")")
   dbg.print("short: ",tostring(t.modName),", full: ",tostring(t.modFullName),"\n")
   dbg.print("fn: ",tostring(t.fn),", default: ",tostring(t.default),"\n")
   s_loadOrder = s_loadOrder + 1
   local mT = self.mT
   local loadOrder = s_loadOrder
   if (status == "inactive") then
      loadOrder = -1
   end
   mT[t.modName] = { fullName  = t.modFullName,
                     short     = t.modName,
                     FN        = t.fn,
                     default   = t.default,
                     mType     = t.mType,
                     status    = status,
                     loadOrder = s_loadOrder,
                     propT     = {},
   }
   if (t.hash and t.hash ~= 0) then
      mT[t.modName].hash = t.hash
   end
   dbg.fini()
end

function M.fileName(self, moduleName)
   local mT    = self.mT
   local sn    = shortName(moduleName)
   local entry = mT[sn]
   if (entry == nil) then
      return nil
   end
   return entry.FN
end

function M.setStatus(self, moduleName, status)
   local mT    = self.mT
   local sn    = shortName(moduleName)
   local entry = mT[sn]
   if (entry ~= nil) then
      entry.status = status
   end
end

function M.haveSN(self, moduleName, status)
   local mT    = self.mT
   local sn    = shortName(moduleName)
   local entry = mT[sn]
   if (entry == nil) then
      return false
   end
   if (sn == entry.short) then
      return ((status == "any") or (status == entry.status))
   end
   return false
end

function M.have(self, moduleName, status)
   local dbg   = Dbg:dbg()
   local mT    = self.mT
   local sn    = shortName(moduleName)
   local entry = mT[sn]
   if (entry == nil) then
      return false
   end
   if (sn == moduleName) then
      return ((status == "any") or (status == entry.status))
   end

   if (moduleName == entry.fullName) then
      return ((status == "any") or (status == entry.status))
   end

   moduleName = moduleName .. '/'
   moduleName = moduleName:gsub("//+",'/')

   if (entry.fullName:find(moduleName)) then
      return ((status == "any") or (status == entry.status))
   end

   return false
end

function M.list(self, kind, status)
   local mT   = self.mT
   local icnt = 0
   local a    = {}
   local b    = {}
   local nameT

   for k,v in pairs(mT) do
      if ((status == "any" or status == v.status) and
          (v.status ~= "pending")) then
         icnt  = icnt + 1
         nameT = kind
         if (kind == "userName") then
            if (v.default == 1) then
               nameT = "short"
            else
               nameT = "fullName"
            end
         end
         a[icnt] = { v[nameT], v.loadOrder}
      end
   end

   table.sort (a, function(x,y) return x[2] < y[2] end)

   for i = 1, icnt do
      b[i] = a[i][1]
   end
   return b
end

function M.setHashSum(self)
   local mT   = self.mT
   local dbg  = Dbg:dbg()

   for k,v in pairs(mT) do
      local a = {}
      if (v.status == "active") then
         a[#a + 1]    = pathJoin(cmdDir(),"computeHashSum")
         if (dbg.active()) then
            a[#a + 1] = "-d"
         end
         a[#a + 1]  = v.FN
         local cmd  = concatTbl(a," ")
         local s    = capture(cmd)
         v.hash     = s:sub(1,-2)
      end
   end
end

function M.getHash(self, moduleName)
   local mT    = self.mT
   local sn    = shortName(moduleName)
   local entry = mT[sn]
   if (entry == nil) then
      return nil
   end
   return entry.hash
end


function M.hideHash(self)
   local mT   = self.mT
   for k,v in pairs(mT) do
      if (v.status == "active") then
         v.hash    = nil
      end
   end
end


function M.markDefault(self, moduleName)
   local mT = self.mT
   local sn = shortName(moduleName)
   local entry = mT[sn]
   if (entry ~= nil) then
      mT[sn].default = 1
   end
end

function M.default(self, moduleName)
   local mT    = self.mT
   local sn    = shortName(moduleName)
   local entry = mT[sn]
   if (entry == nil) then
      return nil
   end
   return (entry.default ~= 0)
end

function M.setLoadOrder(self)
   local a  = self:list("short","active")
   local mT = self.mT
   local sz = #a

   for i = 1,sz do
      local sn = a[i]
      mT[sn].loadOrder = i
   end      
   return sz
end

function M.fullName(self,moduleName)
   local mT    = self.mT
   local sn    = shortName(moduleName)
   local entry = mT[sn]
   if (entry == nil) then
      return nil
   end
   return entry.fullName
end

function M.short(self,moduleName)
   local mT    = self.mT
   local sn    = shortName(moduleName)
   local entry = mT[sn]
   if (entry == nil) then
      return nil
   end
   return entry.short
end

function M.mType(self,moduleName)
   local mT    = self.mT
   local sn    = shortName(moduleName)
   local entry = mT[sn]
   if (entry == nil) then
      return nil
   end
   return entry.mType
end

function M.set_mType(self,moduleName, value)
   local mT    = self.mT
   local sn    = shortName(moduleName)
   local entry = mT[sn]
   if (entry ~= nil) then
      mT[sn].mType = value
   end
end


function M.remove(self, moduleName)
   local dbg = Dbg:dbg()
   local mT = self.mT
   local sn = shortName(moduleName)
   mT[sn] = nil
end

function M.safeToSave(self)
   local mT = self.mT
   local a  = {}
   for k,v in pairs(mT) do
      if (v.status == "active" and v.mType == "mw") then
         a[#a+1] = k
      end
   end
   return a
end



function M.add_property(self, moduleName, name, value)
   local dbg = Dbg:dbg()
   dbg.start("MT:add_property(\"",moduleName,"\", \"",name,"\", \"",tostring(value),"\")")
   
   local mT    = self.mT
   local sn    = shortName(moduleName)
   local entry = mT[sn]

   if (entry == nil) then
      LmodError("MT:add_property(): Did not find module entry: ",moduleName,
                ". This should not happen!\n")
   end
   local propDisplayT = readRC()
   local propKindT    = propDisplayT[name]

   if (propKindT == nil) then
      LmodError("MT:add_property(): system property table has no entry for: ", name,
                "\nCheck spelling and case of name\n")
   end
   local validT = propKindT.validT
   if (validT == nil) then
      LmodError("MT:add_property(): system property table has no validT table for: ", name,
                "\nCheck spelling and case of name\n")
   end

   local propT        = entry.propT
   propT[name]        = propT[name] or {}
   local t            = propT[name]

   for v in value:split(":") do
      if (validT[v] == nil) then
         LmodError("MT:add_property(): The validT table for ", name," has no entry for: ", value,
                   "\nCheck spelling and case of name\n")
      end
      t[v] = 1
   end
   entry.propT[name]  = t

   dbg.fini()
end

function M.remove_property(self, moduleName, name, value)
   local dbg = Dbg:dbg()
   dbg.start("MT:remove_property(\"",moduleName,"\", \"",name,"\", \"",tostring(value),"\")")
   
   local mT    = self.mT
   local sn    = shortName(moduleName)
   local entry = mT[sn]

   if (entry == nil) then
      LmodError("MT:remove_property(): Did not find module entry: ",moduleName,
                ". This should not happen!\n")
   end
   local propDisplayT = readRC()
   local propKindT    = propDisplayT[name]

   if (propKindT == nil) then
      LmodError("MT:remove_property(): system property table has no entry for: ", name,
                "\nCheck spelling and case of name\n")
   end
   local validT = propKindT.validT
   if (validT == nil) then
      LmodError("MT:remove_property(): system property table has no validT table for: ", name,
                "\nCheck spelling and case of name\n")
   end

   local propT        = entry.propT or {}
   local t            = propT[name] or {}

   for v in value:split(":") do
      if (validT[v] == nil) then
         LmodError("MT:add_property(): The validT table for ", name," has no entry for: ", value,
                   "\nCheck spelling and case of name\n")
      end
      t[v] = nil
   end
   entry.propT       = propT
   entry.propT[name] = t
   dbg.fini()
end


function M.list_property(self, idx, moduleName, style, legendT)
   local dbg    = Dbg:dbg()
   dbg.start("MT:list_property(\"",moduleName,"\", \"",style,"\")")
   local dbg = Dbg:dbg()
   local mT    = self.mT
   local sn    = shortName(moduleName)
   local entry = mT[sn]

   if (entry == nil) then
      LmodError("MT:list_property(): Did not find module entry: ",moduleName,
                ". This should not happen!\n")
   end

   local resultA      = colorizePropA(style, moduleName, entry.propT, legendT)

   table.insert(resultA, 1, "  "  .. tostring(idx) ..")")

   local tLen = resultA[1]:len() + resultA[2]:len() + tostring(resultA[3]):len()
   dbg.print("result: \"",resultA[1],"\", \"",resultA[2],
             "\", \"",tostring(resultA[3]),"\"\n")

   dbg.print("tlen: ",tostring(tLen)," lenA: ",resultA[1]:len()," ",resultA[2]:len(),
             " ",tostring(resultA[3]):len(),"\n")

   dbg.fini()
   return resultA
end


function M.reportChanges(self, origMT)
   local dbg    = Dbg:dbg()
   dbg.start("MT:reportChanges(origMT)")


   local mT = origMT.mT

   local inactiveA = {}
   local activeA   = {}
   local changedA  = {}
   local reloadA   = {}

   for k, v in pairs(mT) do
      
      if (self:have(k,"inactive") and v.status == "active") then
         local name = v.fullName
         if (v.default ~= 0) then
            name = v.short
         end
         inactiveA[#inactiveA+1] = name
      elseif (self:have(k,"active")) then
         if ( v.status == "inactive") then
            activeA[#activeA+1] = self:fullName(k)
         elseif (self:fileName(k) ~= v.FN ) then
            if (self:fullName(k) == v.fullName) then
               reloadA[#reloadA+1] = v.fullName
            else
               changedA[#changedA+1] = v.fullName .. " => " .. self:fullName(k)
            end
         end
      end
   end
      
   local entries = false

   if (#inactiveA > 0) then
      entries = true
      columnList(io.stderr,"\nInactive Modules:\n", inactiveA)
   end
   if (#activeA > 0) then
      entries = true
      columnList(io.stderr,"\nActivating Modules:\n", activeA)
   end
   if (#reloadA > 0) then
      entries = true
      columnList(io.stderr,"\nDue to MODULEPATH changes the following have been reloaded:\n",
                 reloadA)
   end
   if (#changedA > 0) then
      entries = true
      columnList(io.stderr,"\nThe following have been reloaded with a version change:\n", changedA)
   end

   if (entries) then
      io.stderr:write("\n")
   end

   dbg.fini()
end


function M.serializeTbl(self)
   
   s_mt.activeSize = self:setLoadOrder()

   local s = _G.serializeTbl{ indent=false, name=self.name(), value=s_mt}
   return s:gsub("[ \n]","")
end

return M
