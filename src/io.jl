# All the IO related APIs.

export readdata, readlogdata, readtecdata, showhead

const tag = 4 # Fortran record tag

searchdir(path, key) = filter(x->occursin(key, x), readdir(path))

function Base.show(io::IO, data::Data)
   showhead(io, data)
   if data.list.bytes ≥ 1e9
      println(io, "filesize = $(data.list.bytes/1e9) GB")
   elseif data.list.bytes ≥ 1e6
      println(io, "filesize = $(data.list.bytes/1e6) MB")
   elseif data.list.bytes ≥ 1e3
      println(io, "filesize = $(data.list.bytes/1e3) KB")
   else
      println(io, "filesize = $(data.list.bytes) bytes")
   end
   println(io, "snapshots = $(data.list.npictinfiles)")
end

"""
	readdata(filenameIn; dir=".", npict=1, verbose=false)

Read data from BATSRUS output files. Stores the `npict` snapshot from an ascii or binary
data file into the arrays of coordinates `x` and data `w`.
Filename can be provided with wildcards.

# Examples
```
data = readdata("1d_raw*")
```
"""
function readdata(filenameIn::AbstractString; dir::String=".", npict::Int=1,
   verbose::Bool=false)
   # Check the existence of files
   filename = searchdir(dir, Regex(replace(filenameIn, s"*" => s".*")))
   if isempty(filename)
      throw(ArgumentError("No matching filename was found for $(filenameIn)"))
   elseif length(filename) > 1
      throw(ArgumentError("Ambiguous filename $(filenameIn)!"))
   end

   filelist, fileID, pictsize = getfiletype(filename[1], dir)

   verbose &&
      @info "filename=$(filelist.name)\n"*"npict=$(filelist.npictinfiles)"

   if filelist.npictinfiles - npict < 0
      throw(ArgumentError("select snapshot $npict out of range $(filelist.npictinfiles)!"))
   end
   seekstart(fileID) # Rewind to start

   ## Read data from files
   # Skip npict-1 snapshots (because we only want the npict-th snapshot)
   skip(fileID, pictsize*(npict-1))

   filehead = getfilehead(fileID, filelist.type)

   # Read data
   fileType = lowercase(filelist.type)
   if fileType == "ascii"
      x, w = allocateBuffer(filehead, Float64) # why Float64?
      getascii!(x, w, fileID, filehead)
   else
      skip(fileID, tag) # skip record start tag.
      T = fileType == "real4" ? Float32 : Float64
      x, w = allocateBuffer(filehead, T)
      getbinary!(x, w, fileID, filehead, T)
   end

   close(fileID)

   #setunits(filehead,"")

	data = Data(filehead, x, w, filelist)

   verbose && @info "Finished reading $(filelist.name)"

   data
end

"Read information from log file."
function readlogdata(filename::AbstractString)
   f = open(filename, "r")
   nLine = countlines(f) - 2
   seekstart(f)
   headline  = readline(f)
   variables = split(readline(f))
   ndim      = 1
   it        = 0
   t         = 0.0
   gencoord  = false
   nx        = 1
   nw        = length(variables)

   data = zeros(nw,nLine)
   for i = 1:nLine
      line = split(readline(f))
      data[:,i] = parse.(Float64, line)
   end

   close(f)

   head = (ndim=ndim, headline=headline, it=it, time=t, gencoord=gencoord,
      nw=nw, nx=nx, variables=variables)

   head, data
end

"""
	readtecdata(filename; doGeometry=false, verbose=false)

Return header, data and connectivity from BATSRUS Tecplot outputs. Both 2D and
3D binary and ASCII formats are supported.
# Examples
```
filename = "3d_ascii.dat"
head, data, connectivity = readtecdata(filename)
```
"""
function readtecdata(filename::AbstractString; doGeometry::Bool=false,
                                               verbose::Bool=false)
   f = open(filename)

   nDim  = 3
   nNode = Int32(0)
   nCell = Int32(0)
   ET = ""

   # Read Tecplot header
   ln = readline(f) |> strip
   if startswith(ln, "TITLE")
      title = match(r"\"(.*?)\"", split(ln,'=', keepempty=false)[2])[1]
   else
      @warn "No title provided."
   end
   ln = readline(f) |> strip
   if startswith(ln, "VARIABLES")
      # Read until another keyword appears
      varline = split(ln,'=')[2]

      ln = readline(f) |> strip
      while !startswith(ln, "ZONE")
         varline *= strip(ln)
         ln = readline(f) |> strip
      end
      VARS = split(varline, '\"')
      deleteat!(VARS,findall(x -> x in (" ",", ") || isempty(x), VARS))
   else
      @warn "No variable names provided."
   end

   while !startswith(ln, "AUXDATA")
      if !startswith(ln, "ZONE") # ZONE allows multiple \n
         zoneline = split(ln, ", ", keepempty=false)
      else # if the ZONE line has nothing, this won't work!
         zoneline = split(ln[6:end], ", ", keepempty=false)
         replace(zoneline[1], '"'=>"") # Remove the quotes in T
      end
      for zline in zoneline
         name, value = split(zline,'=', keepempty=false)
         name = uppercase(name)
         if name == "T" # ZONE title
            T = value
         elseif name in ("NODES","N")
            nNode = parse(Int32, value)
         elseif name in ("ELEMENTS","E")
            nCell = parse(Int32, value)
         elseif name in ("ET","ZONETYPE")
            if uppercase(value) in ("BRICK","FEBRICK")
               nDim = 3
            elseif uppercase(value) in ("QUADRILATERAL", "FEQUADRILATERAL")
               nDim = 2
            end
            ET = uppercase(value)
         end
      end
      ln = readline(f) |> strip
   end
    # if geometry is called for it means we want cc data with nodal XYZ
    if !doGeometry
        nData = nNode
        nConn = nCell
        nGeom = nNode
    else
        nData = nCell
        nConn = nCell
        nGeom = nNode
    end

   auxdataname = String[]
   auxdata = Union{Int32, String}[]
   pt0 = position(f)

   while startswith(ln, "AUXDATA") || startswith(ln,"DT")
      name, value = split(ln,'"', keepempty=false)
      name = string(name[9:end-1])
      str = string(strip(value))
      if name in ("ITER","NPROC")
         str = parse(Int32, value)
      elseif name == "TIMESIM"
         sec = split(str,"=")
         str = string(strip(sec[2]))
      end
      push!(auxdataname, name)
      push!(auxdata, str)

      pt0 = position(f)
      ln = readline(f) |> strip
   end

   seek(f, pt0)

   data = Array{Float32,2}(undef, length(VARS), nData)

   if nDim == 3
	   connectivity = Array{Int32,2}(undef,8,nConn)
       if doGeometry
          geometry = Array{Float32,2}(undef,3,nGeom)
       end
   elseif nDim == 2
	   connectivity = Array{Int32,2}(undef,4,nConn)
       if doGeometry
          geometry = Array{Float32,2}(undef,2,nGeom)
       end
   end

   IsBinary = false
   try
      parse.(Float32, split(readline(f)))
   catch
      IsBinary = true
      verbose && @info "reading binary file"
   end

   seek(f, pt0)

   if IsBinary
	   @inbounds for i = 1:nData
		   read!(f, @view data[:,i])
	   end
	   @inbounds for i = 1:nConn
         read!(f, @view connectivity[:,i])
       end
       if doGeometry
	      @inbounds for i = 1:nGeom
             read!(f, @view geometry[:,i])
          end
       end
   else
      @inbounds for i = 1:nData
         x = readline(f)
         data[:,i] .= parse.(Float32, split(x))
      end
	  @inbounds for i = 1:nCell
		   x = readline(f)
		   connectivity[:,i] .= parse.(Int32, split(x))
	  end
      if doGeometry
	      @inbounds for i = 1:nGeom
		     x = readline(f)
		     geometry[:,i] .= parse.(Float32, split(x))
          end
      end
   end

   close(f)

   head = (variables=VARS, nCell=nCell, nNode=nNode, nData=nData, nConn=nConn,
           nGeom=nGeom, nDim=nDim, ET=ET, title=title,
           auxdataname=auxdataname, auxdata=auxdata)

   results = Dict{String,Array}("data"         => data,
                                "connectivity" => connectivity)
   if doGeometry
       results["geometry"] = geometry
   end

   head, results
end

"Obtain file type."
function getfiletype(filename::String, dir::String)
   file = joinpath(dir, filename)
   fileID = open(file, "r")
   bytes = filesize(file)
   type  = ""

   # Check the appendix of file names
   # Gabor uses a trick: the first 4 bytes decides the file type
   if occursin(r"^.*\.(log)$", filename)
      type = "log"
      npictinfiles = 1
   elseif occursin(r"^.*\.(dat)$", filename)
      # Tecplot ascii format
      type = "dat"
      npictinfiles = 1
   else
      # Obtain filetype based on the length info in the first 4 bytes
      lenhead = read(fileID, Int32)

      if lenhead!=79 && lenhead!=500
         type = "ascii"
      else
         # The length of the 2nd line decides between real4 & real8
         # since it contains the time; which is real*8 | real*4
         skip(fileID, lenhead+tag)
         len = read(fileID, Int32)
         if len == 20
            type = "real4"
         elseif len == 24
            type = "binary"
         else
            throw(ArgumentError(
               "Error in getfiletype: incorrect formatted file: $filename"))
         end

         if lenhead == 500
            type = uppercase(type)
         end
      end
      # Obtain file size & number of snapshots
      seekstart(fileID)
      pictsize = getfilesize(fileID, type)
      npictinfiles = bytes ÷ pictsize
   end

   filelist = FileList(filename, type, dir, bytes, npictinfiles)

   filelist, fileID, pictsize
end

"""
	getfilehead(fileID, type) -> NameTuple

Obtain the header information from BATSRUS output file of `type` linked to `fileID`.
# Input arguments
- `fileID::IOStream`: file identifier.
- `type::String`: file type in ["ascii", "real4", "binary", "log"].
"""
function getfilehead(fileID::IOStream, type::String)
   ftype = string(lowercase(type))

   lenstr = ftype == type ? 79 : 500

   ## Read header
   pointer0 = position(fileID)

   if ftype == "ascii"
      headline = readline(fileID)
      line = readline(fileID)
      line = split(line)
      it = parse(Int,line[1])
      t = parse(Float64,line[2])
      ndim = parse(Int8,line[3])
      neqpar = parse(Int32,line[4])
      nw = parse(Int8,line[5])
      gencoord = ndim < 0
      ndim = abs(ndim)
      nx = parse.(Int64, split(readline(fileID)))
      if neqpar > 0
         eqpar = parse.(Float64, split(readline(fileID)))
      end
      varname = readline(fileID)
   elseif ftype ∈ ["real4", "binary"]
      skip(fileID, tag) # skip record start tag.
      headline = rstrip(String(read(fileID, lenstr)))
      skip(fileID, 2*tag) # skip record end/start tags.
      it = read(fileID, Int32)
      t = read(fileID, Float32)
      ndim = read(fileID, Int32)
      gencoord = (ndim < 0)
      ndim = abs(ndim)
      neqpar = read(fileID, Int32)
      nw = read(fileID, Int32)
      skip(fileID, 2*tag) # skip record end/start tags.
      nx = zeros(Int32, ndim)
      read!(fileID, nx)
      skip(fileID, 2*tag) # skip record end/start tags.
      if neqpar > 0
         eqpar = zeros(Float32, neqpar)
         read!(fileID, eqpar)
         skip(fileID, 2*tag) # skip record end/start tags.
      end
      varname = String(read(fileID, lenstr))
      skip(fileID, tag) # skip record end tag.
   end

   # Header length
   pointer1 = position(fileID)
   headlen = pointer1 - pointer0

   # Set variables array
   variables = split(varname) # returns a string array

	# Produce a wnames from the last file
   wnames = variables[ndim+1:ndim+nw]

   head = (ndim=ndim, headline=headline, it=it, time=t, gencoord=gencoord,
		neqpar=neqpar, nw=nw, nx=nx, eqpar=eqpar, variables=variables,
		wnames=wnames)
end

function skipline(s::IO)
   while !eof(s)
       c = read(s, Char)
       c == '\n' && break
   end
   return
end

"Return the size in bytes for one snapshot."
function getfilesize(fileID::IOStream, type::String)
   ftype = string(lowercase(type))

   if ftype == type lenstr = 79 else lenstr = 500 end

   # Read header
   pointer0 = position(fileID)

   if ftype == "ascii"
      skipline(fileID)
      line = readline(fileID)
      line = split(line)
      ndim = parse(Int32,line[3])
      neqpar = parse(Int32,line[4])
      nw = parse(Int8,line[5])
      gencoord = ndim < 0
      ndim = abs(ndim)
      nx = parse.(Int64, split(readline(fileID)))
      neqpar > 0 && skipline(fileID)
      skipline(fileID)
   elseif ftype ∈ ("real4", "binary")
      skip(fileID, tag)
      read(fileID, lenstr)
      skip(fileID, 2*tag)
      read(fileID, Int32)
      read(fileID, Float32)
      ndim = abs(read(fileID, Int32))
      tmp = read(fileID, Int32)
      nw = read(fileID, Int32)
      skip(fileID, 2*tag)
      nx = zeros(Int32, ndim)
      read!(fileID, nx)
      skip(fileID, 2*tag)
      if tmp > 0
         tmp2 = zeros(Float32, tmp)
         read!(fileID, tmp2)
         skip(fileID, 2*tag) # skip record end/start tags.
      end
      read(fileID, lenstr)
      skip(fileID, tag)
   end

   # Header length
   pointer1 = position(fileID)
   headlen = pointer1 - pointer0

   # Calculate the snapshot size = header + data + recordmarks
   nxs = prod(nx)
   if ftype == "log"
      pictsize = 1
   elseif ftype == "ascii"
      pictsize = headlen + (18*(ndim+nw)+1)*nxs
   elseif ftype == "real4"
      pictsize = headlen + 8*(1+nw) + 4*(ndim+nw)*nxs
   elseif ftype == "binary"
      pictsize = headlen + 8*(1+nw) + 8*(ndim+nw)*nxs
   end

   pictsize
end

"Create buffer for x and w."
function allocateBuffer(filehead::NamedTuple, T::DataType)
   if filehead.ndim == 1
      n1 = filehead.nx[1]
      x  = Array{T,2}(undef,n1,filehead.ndim)
      w  = Array{T,2}(undef,n1,filehead.nw)
   elseif filehead.ndim == 2
      n1, n2 = filehead.nx
      x  = Array{T,3}(undef,n1,n2,filehead.ndim)
      w  = Array{T,3}(undef,n1,n2,filehead.nw)
   elseif filehead.ndim == 3
      n1, n2, n3 = filehead.nx
      x  = Array{T,4}(undef,n1,n2,n3,filehead.ndim)
      w  = Array{T,4}(undef,n1,n2,n3,filehead.nw)
   end

   x, w
end

"Read ascii format data."
function getascii!(x, w, fileID::IOStream, filehead::NamedTuple)
   ndim, nx = filehead.ndim, filehead.nx

   # Read coordinates & values row by row
   if ndim == 1 # 1D
      for ix = 1:nx[1]
         temp = parse.(Float64, split(readline(fileID)))
         x[ix,:] .= temp[1]
         w[ix,:] .= temp[2:end]
      end
   elseif ndim == 2 # 2D
      for j = 1:nx[2], i = 1:nx[1]
         temp = parse.(Float64, split(readline(fileID)))
         x[i,j,:] .= temp[1:2]
         w[i,j,:] .= temp[3:end]
      end
   elseif ndim == 3 # 3D
      for k = 1:nx[3], j = 1:nx[2], i = 1:nx[1]
         temp = parse.(Float64, split(readline(fileID)))
         x[i,j,k,:] .= temp[1:3]
         w[i,j,k,:] .= temp[4:end]
      end
   end

   return
end


"Read binary format data."
function getbinary!(x, w, fileID::IOStream, filehead::NamedTuple, T::DataType)
   ndim, nw = filehead.ndim, filehead.nw

   # Read coordinates & values
   if ndim == 1 # 1D
      read!(fileID, x)
      skip(fileID, 2*tag) # skip record end/start tags.
      for iw = 1:nw
         read!(fileID, @view w[:,iw])
         skip(fileID, 2*tag) # skip record end/start tags.
      end
   elseif ndim == 2 # 2D
      read!(fileID, x)
      skip(fileID, 2*tag) # skip record end/start tags.
      for iw = 1:nw
         read!(fileID, @view w[:,:,iw])
         skip(fileID, 2*tag) # skip record end/start tags.
      end
   elseif ndim == 3 # 3D
      read!(fileID, x)
      skip(fileID, 2*tag) # skip record end/start tags.
      for iw = 1:nw
         read!(fileID, @view w[:,:,:,iw])
         skip(fileID, 2*tag) # skip record end/start tags.
      end
   end

   return
end

"""
	setunits(filehead, type; distance=1.0, mp=1.0, me=1.0)

Set the units for the output files.
If type is given as "SI", "CGS", "NORMALIZED", "PIC", "PLANETARY", "SOLAR", set
`typeunit = type`, otherwise try to guess from the fileheader. Based on `typeunit` set units
for distance [xSI], time [tSI], density [rhoSI], pressure [pSI], magnetic field [bSI] and
current density [jSI] in SI units. Distance unit [rplanet | rstar], ion and electron mass in
[amu] can be set with optional `distance`, `mp` and `me`.

Also calculate convenient constants ti0, cs0 ... for typical formulas.
This function is currently not used anywhere!
"""
function setunits(filehead, type; distance=1.0, mp=1.0, me=1.0)
   ndim      = filehead.ndim
   headline  = filehead.headline
   neqpar    = filehead.neqpar
   nw        = filehead.nw
   eqpar     = filehead.eqpar
   variables = filehead.variables

   mu0SI = 4π*1e-7      # H/m
   cSI   = 2.9978e8       # speed of light, [m/s]
   mpSI  = 1.6726e-27     # kg
   eSI   = 1.602e-19      # elementary charge, [C]
   AuSI  = 149597870700   # m
   RsSI  = 6.957e8        # m
   Mi    = 1.0            # Ion mass, [amu]
   Me    = 1.0/1836.15    # Electron mass, [amu]
   gamma = 5/3            # Adiabatic index for first fluid
   gammae= 5/3            # Adiabatic index for electrons
   kbSI  = 1.38064852e-23 # Boltzmann constant, [m2 kg s-2 K-1]
   e0SI  = 8.8542e-12     # [F/m]

   # This part is used to guess the units.
   # To be honest; I don`t understand the logic here. For example
   # nPa & m/s may appear in the same headline?
   if type !== ""
      typeunit = uppercase(type)
   elseif occursin("PIC", headline)
      typeunit = "PIC"
   elseif occursin(" AU ", headline)
      typeunit = "OUTERHELIO"
   elseif occursin(r"(kg/m3)|(m/s)", headline)
      typeunit = "SI"
   elseif occursin(r"(nPa)|( nT )", headline)
      typeunit = "PLANETARY"
   elseif occursin(r"(dyne)|( G)", headline)
      typeunit = "SOLAR"
   else
      typeunit = "NORMALIZED"
   end

   if typeunit == "SI"
      xSI   = 1.0             # m
      tSI   = 1.0             # s
      rhoSI = 1.0             # kg/m^3
      uSI   = 1.0             # m/s
      pSI   = 1.0             # Pa
      bSI   = 1.0             # T
      jSI   = 1.0             # A/m^2
   elseif typeunit == "CGS"
      xSI   = 0.01            # cm
      tSI   = 1.0             # s
      rhoSI = 1000.0          # g/cm^3
      uSI   = 0.01            # cm/s
      pSI   = 0.1             # dyne/cm^2
      bSI   = 1.0e-4          # G
      jSI   = 10*cSI          # Fr/s/cm^2
   elseif typeunit == "PIC"
      # Normalized PIC units
      xSI   = 1.0             # cm
      tSI   = 1.0             # s
      rhoSI = 1.0             # g/cm^3
      uSI   = 1.0             # cm/s
      pSI   = 1.0             # dyne/cm^2
      bSI   = 1.0             # G
      jSI   = 1.0             # Fr/s/cm^2
      c0    = 1.0             # speed of light always 1 for iPIC3D
   elseif typeunit == "NORMALIZED"
      xSI   = 1.0             # distance unit in SI
      tSI   = 1.0             # time unit in SI
      rhoSI = 1.0             # density unit in SI
      uSI   = 1.0             # velocity unit in SI
      pSI   = 1.0             # pressure unit in SI
      bSI   = √mu0SI     # magnetic unit in SI
      jSI   = 1/√(mu0SI)   # current unit in SI
      c0    = 1.0             # speed of light (for Boris correction)
   elseif typeunit == "PLANETARY"
      xSI   = 6378000         # Earth radius [default planet]
      tSI   = 1.0             # s
      rhoSI = mpSI*1e6        # mp/cm^3
      uSI   = 1e3             # km/s
      pSI   = 1e-9            # nPa
      bSI   = 1e-9            # nT
      jSI   = 1e-6            # muA/m^2
      c0    = cSI/uSI         # speed of light in velocity units
   elseif typeunit == "OUTERHELIO"
      xSI   = AuSI            # AU
      tSI   = 1.0             # s
      rhoSI = mpSI*1e6        # mp/cm^3
      uSI   = 1e3             # km/s
      pSI   = 1e-1            # dyne/cm^2
      bSI   = 1e-9            # nT
      jSI   = 1e-6            # muA/m^2
      c0    = cSI/uSI         # speed of light in velocity units
   elseif typeunit == "SOLAR"
      xSI   = RsSI            # radius of the Sun
      tSI   = 1.0             # s
      rhoSI = 1e3             # g/cm^3
      uSI   = 1e3             # km/s
      pSI   = 1e-1            # dyne/cm^2
      bSI   = 1e-4            # G
      jSI   = 1e-6            # muA/m^2
      c0    = cSI/uSI         # speed of light in velocity units
   else
      throw(ArgumentError("invalid typeunit=$(typeunit)"))
   end

   # Overwrite values if given by eqpar
   for ieqpar = 1:neqpar
      var = variables[ndim+nw+ieqpar]
      if var == "xSI"
         xSI   = eqpar[ieqpar]
      elseif var == "tSI"
         tSI   = eqpar[ieqpar]
      elseif var == "uSI"
         uSI   = eqpar[ieqpar]
      elseif var == "rhoSI"
         rhoSI = eqpar[ieqpar]
      elseif var == "mi"
         mi    = eqpar[ieqpar]
      elseif var == "m1"
         m1    = eqpar[ieqpar]
      elseif var == "me"
         me    = eqpar[ieqpar]
      elseif var == "qi"
         qi    = eqpar[ieqpar]
      elseif var == "q1"
         q1    = eqpar[ieqpar]
      elseif var == "qe"
         qe    = eqpar[ieqpar]
      elseif var == "g"
         gamma = eqpar[ieqpar]
      elseif var == "g1"
         gamma = eqpar[ieqpar]
      elseif var == "ge"
         ge    = eqpar[ieqpar]
      elseif var == "c"
         c     = eqpar[ieqpar]
      elseif var == "clight"
         clight= eqpar[ieqpar]
      elseif var == "r"
         r     = eqpar[ieqpar]
      elseif var == "rbody"
         rbody = eqpar[ieqpar]
      end
   end

   # Overwrite distance unit if given as an argument
   if !isempty(distance) xSI = distance end

   # Overwrite ion & electron masses if given as an argument
   if !isempty(mp)      Mi = mp end
   if !isempty(me) Me = me end

   # Calculate convenient conversion factors
   if typeunit == "NORMALIZED"
      ti0  = 1.0/Mi            # T      = p/rho*Mi           = ti0*p/rho
      cs0  = 1.0               # cs     = sqrt(gamma*p/rho)  = sqrt(gs*p/rho)
      mu0A = 1.0               # vA     = sqrt(b/rho)        = sqrt(bb/mu0A/rho)
      mu0  = 1.0               # beta   = p/(bb/2)           = p/(bb/(2*mu0))
      uH0  = Mi                # uH     = j/rho*Mi           = uH0*j/rho
      op0  = 1.0/Mi            # omegap = sqrt(rho)/Mi       = op0*sqrt(rho)
      oc0  = 1.0/Mi            # omegac = b/Mi               = oc0*b
      rg0  = √Mi               # rg = sqrt(p/rho)/b*sqrt(Mi) = rg0*sqrt(p/rho)/b
      di0  = c0*Mi             # di = c0/sqrt(rho)*Mi        = di0/sqrt(rho)
      ld0  = Mi                # ld = sqrt(p)/(rho*c0)*Mi    = ld0*sqrt(p)/rho
   elseif typeunit == "PIC"
      ti0  = 1.0/Mi            # T      = p/rho*Mi           = ti0*p/rho
      cs0  = 1.0               # cs     = sqrt(gamma*p/rho)  = sqrt(gs*p/rho)
      mu0A = 4*pi              # vA     = sqrt(b/(4*!pi*rho))= sqrt(bb/mu0A/rho)
      mu0  = 4*pi              # beta   = p/(bb/(8*!pi))     = p/(bb/(2*mu0))
      uH0  = Mi                # uH     = j/rho*Mi           = uH0*j/rho
      op0  = √(4π)/Mi          # omegap = sqrt(4*!pi*rho)/Mi = op0*sqrt(rho)
      oc0  = 1.0/Mi            # omegac = b/Mi               = oc0*b
      rg0  = √Mi               # rg = sqrt(p/rho)/b*sqrt(Mi) = rg0*sqrt(p/rho)/b
      di0  = 1.0/√(4π)         # di = 1/sqrt(4*!pi*rho)*Mi   = di0/sqrt(rho)
      ld0  = 1.0/√(4π)         # ld = sqrt(p/(4*!pi))/rho*Mi = ld0*sqrt(p)/rho
   else
      qom  = eSI/(Mi*mpSI); moq = 1/qom
      ti0  = mpSI/kbSI*pSI/rhoSI*Mi       # T[K]=p/(nk) = ti0*p/rho
      cs0  = pSI/rhoSI/uSI^2              # cs          = sqrt(gs*p/rho)
      mu0A = uSI^2*mu0SI*rhoSI*bSI^(-2)   # vA          = sqrt(bb/(mu0A*rho))
      mu0  = mu0SI*pSI*bSI^(-2)           # beta        = p/(bb/(2*mu0))
      uH0  = moq*jSI/rhoSI/uSI            # uH=j/(ne)   = uH0*j/rho
      op0  = qom*√(rhoSI/e0SI)*tSI        # omegap      = op0*sqrt(rho)
      oc0  = qom*bSI*tSI                  # omegac      = oc0*b
      rg0  = moq*√(pSI/rhoSI)/bSI/xSI/√(Mi)    # rg     = rg0*sqrt(p/rho)/b
      di0  = cSI/(op0/tSI)/xSI                 # di=c/omegap = di0/sqrt(rho)
      ld0  = moq*√(pSI)/rhoSI/xSI              # ld          = ld0*sqrt(p)/rho
   end
   return true
end

"""
	showhead(file, filehead)

Displaying file header information.
"""
function showhead(file::FileList, head, io=stdout)
   println(io, "filename : $(file.name)")
   println(io, "filetype : $(file.type)")
   println(io, "headline : $(head.headline)")
   println(io, "iteration: $(head.it)")
   println(io, "time     : $(head.time)")
   println(io, "gencoords: $(head.gencoord)")
   println(io, "ndim     : $(head.ndim)")
   println(io, "neqpar   : $(head.neqpar)")
   println(io, "nw       : $(head.nw)")
   println(io, "nx       : $(head.nx)")

   if head.neqpar > 0
      println(io, "parameters  = $(head.eqpar)")
      println(io, "coord names = $(head.variables[1:head.ndim])")
      println(io, "var   names = $(head.variables[head.ndim+1:head.ndim+head.nw])")
      println(io, "param names = $(head.variables[head.ndim+head.nw+1:end])")
   end
end

"""
	showhead(data)
   showhead(io, data)

Display file information of `data`.
"""
showhead(data::Data) = showhead(data.list, data.head)
showhead(io, data::Data) = showhead(data.list, data.head, io)
