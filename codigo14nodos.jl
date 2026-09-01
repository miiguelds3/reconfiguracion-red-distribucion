using JuMP, Juniper, Ipopt, HiGHS, CSV, DataFrames, LinearAlgebra, Printf, Plots, Statistics

# ============================================
# CONFIGURACIÓN DEL SISTEMA
# ============================================

# 1. SELECCIONAR ESCENARIO
const ESCENARIO = "14_nodos"  # "5_nodos", "14_nodos", "33_nodos"

# 2. PARÁMETROS DEL SISTEMA
const SBASE_KVA = 1000.0      # Potencia base en kVA
const VBASE_KV = 23           # Voltaje base en kV
const VMIN = 0.90             # Voltaje mínimo en pu
const VMAX = 1.10             # Voltaje máximo en pu
const SLACK_BUS = :N1         # Nodo slack
const GENERADORES = [:G1]     # Lista de generadores

# 3. CONFIGURACIÓN DE GD - DESACTIVADA
const GD_ACTIVO = false        # ← IMPORTANTE: false

# 4. CONFIGURACIÓN COMPENSACIÓN CAPACITIVA - DESACTIVADA
const COMP_CAP_ACTIVA = false  # ← IMPORTANTE: false

# 5. TIE-LINES INICIALMENTE DESCONECTADAS
const TIE_LINES = [:c, :e, :g]  # Vacío si no hay tie-lines, o [:t1, :t2, :t3] 

# 6. ARCHIVOS
const ARCHIVO_FACTORES = "factores.csv"
const ARCHIVO_PERFILES_GD = "perfiles_gd.csv"  # No se usará (GD_ACTIVO = false)

# Los siguientes se determinan según el escenario
function obtener_archivos_escenario(escenario)
    if escenario == "5_nodos"
        return ("cargas5.csv", "lineas5.csv")
    elseif escenario == "14_nodos"
        return ("cargas14.csv", "lineas14.csv")
    elseif escenario == "33_nodos"
        return ("cargas33.csv", "lineas33.csv")
    else
        error("Escenario '$escenario' no reconocido. Usar: '5_nodos', '14_nodos', '33_nodos'")
    end
end

const (ARCHIVO_CARGAS, ARCHIVO_LINEAS) = obtener_archivos_escenario(ESCENARIO)

# ============================================
# MOSTRAR CONFIGURACIÓN
# ============================================
println("═"^60)
println("CONFIGURACIÓN DEL SISTEMA")
println("═"^60)
println("ESCENARIO: $ESCENARIO")
println("\nPARÁMETROS DEL SISTEMA:")
println("  Sbase: $SBASE_KVA kVA")
println("  Vbase: $VBASE_KV kV")
println("  Vmin: $VMIN pu, Vmax: $VMAX pu")
println("  Slack bus: $SLACK_BUS")
println("  Generadores: $(join(GENERADORES, ", "))")
println("\nGENERACIÓN DISTRIBUIDA: $(GD_ACTIVO ? "ACTIVADA" : "DESACTIVADA")")
println("COMPENSACIÓN CAPACITIVA: $(COMP_CAP_ACTIVA ? "ACTIVADA" : "DESACTIVADA")")
println("\nARCHIVOS:")
println("  Factores horarios: $ARCHIVO_FACTORES")
println("  Cargas: $ARCHIVO_CARGAS")
println("  Líneas: $ARCHIVO_LINEAS")
println("═"^60)

# ============================================
# CONFIGURACIÓN DE SOLVERS
# ============================================
nl_solver = optimizer_with_attributes(Ipopt.Optimizer, 
    "print_level" => 0,
    "max_iter" => 10000,
    "tol" => 1e-8,          
    "constr_viol_tol" => 1e-8,
    "acceptable_tol" => 1e-8
)

mip_solver = optimizer_with_attributes(HiGHS.Optimizer, 
    "time_limit" => 600.0,
    "presolve" => "on",
    "mip_rel_gap" => 1e-6
)

juniper_solver = optimizer_with_attributes(
    Juniper.Optimizer,
    "nl_solver" => nl_solver,
    "mip_solver" => mip_solver,
    "log_levels" => [:Info],
    "time_limit" => 600,
    "branch_strategy" => :StrongPseudoCost,
    "solution_limit" => 50,
    "allow_almost_solved" => true,
    "mip_gap" => 1e-6
)

# ============================================
# FUNCIONES PARA CARGA DE DATOS
# ============================================

function cargar_factores_horarios(archivo_factores = ARCHIVO_FACTORES)
    if isfile(archivo_factores)
        df_factores = CSV.read(archivo_factores, DataFrame, delim=';', decimal='.')
        required_cols = ["Hora", "Res_P", "Res_Q", "Com_P", "Com_Q", "Ind_P", "Ind_Q"]
        for col in required_cols
            if !(col in names(df_factores))
                error("Falta la columna '$col' en $archivo_factores")
            end
        end
        println("✓ Factores horarios cargados desde $archivo_factores")
        return df_factores
    else
        error("Archivo de factores no encontrado: $archivo_factores")
    end
end

function generar_demandas_horarias(df_loads, df_factores, horas)
    load_hourly = Dict()
    
    if !("tipo" in names(df_loads))
        error("El archivo $ARCHIVO_CARGAS debe contener la columna 'tipo'")
    end
    
    for row in eachrow(df_loads)
        nodo = Symbol(row.node)
        tipo_str = lowercase(strip(string(row.tipo)))
        tipo = Symbol(tipo_str)
        Pd_base = row.Pd
        Qd_base = row.Qd
        
        if tipo == :slack || (Pd_base == 0.0 && Qd_base == 0.0)
            for h in horas
                load_hourly[(nodo, h)] = (Pd=Pd_base, Qd=Qd_base)
            end
            continue
        end
        
        for h in horas
            fila_hora = df_factores[df_factores.Hora .== h, :]
            if nrow(fila_hora) == 0
                error("No se encontró la hora $h en los factores horarios")
            end
            
            if tipo == :residencial
                factor_P = fila_hora[1, :Res_P]
                factor_Q = fila_hora[1, :Res_Q]
            elseif tipo == :comercial
                factor_P = fila_hora[1, :Com_P]
                factor_Q = fila_hora[1, :Com_Q]
            elseif tipo == :industrial
                factor_P = fila_hora[1, :Ind_P]
                factor_Q = fila_hora[1, :Ind_Q]
            else
                factor_P = fila_hora[1, :Res_P]
                factor_Q = fila_hora[1, :Res_Q]
            end
            
            Pd = Pd_base * factor_P
            Qd = Qd_base * factor_Q
            load_hourly[(nodo, h)] = (Pd=Pd, Qd=Qd)
        end
    end
    
    return load_hourly
end

# ============================================
# CONFIGURACIÓN HORARIA
# ============================================
horas = 1:24

# Cargar factores horarios
println("\nCargando factores horarios...")
df_factores = cargar_factores_horarios()

# ============================================
# LEER DATOS DE RED Y CARGA
# ============================================
println("\nCargando datos de red...")
df_lines = CSV.read(ARCHIVO_LINEAS, DataFrame)
df_loads = CSV.read(ARCHIVO_CARGAS, DataFrame, delim=';')

# Verificar columnas necesarias
println("\nVerificando estructura de $ARCHIVO_CARGAS...")
columnas_requeridas = ["node", "Pd", "Qd", "tipo"]
for col in columnas_requeridas
    if !(col in names(df_loads))
        error("✗ Falta la columna '$col' en $ARCHIVO_CARGAS")
    else
        println("  ✓ Columna '$col' encontrada")
    end
end

# Mostrar información del sistema
println("\n" * "="^60)
println("INFORMACIÓN DEL SISTEMA - ESCENARIO $ESCENARIO")
println("="^60)

println("\nRESUMEN DE CARGA:")
total_pd_pu = sum(df_loads.Pd)
total_qd_pu = sum(df_loads.Qd)
println("  Demanda total: $(round(total_pd_pu, digits=3)) + j$(round(total_qd_pu, digits=3)) pu")
println("  Equivalente: $(round(total_pd_pu * SBASE_KVA, digits=1)) + j$(round(total_qd_pu * SBASE_KVA, digits=1)) kW")

println("\nRESUMEN DE LÍNEAS:")
println("  Total líneas: $(nrow(df_lines))")
println("  Tie-lines: $(length(TIE_LINES))")

# Generar demandas horarias
println("\nGenerando demandas horarias...")
load_hourly = generar_demandas_horarias(df_loads, df_factores, horas)

# ============================================
# CONSTRUIR CONJUNTOS Y PARÁMETROS
# ============================================
nodes = unique(vcat(df_loads.node, df_lines.from, df_lines.to)) .|> Symbol
branches = df_lines.branch .|> Symbol
map_gen_node = Dict(g => SLACK_BUS for g in GENERADORES)

# Diccionario de datos base (solo demanda)
load_base = Dict(Symbol(row.node) => (
    Pd=row.Pd, 
    Qd=row.Qd, 
    tipo=Symbol(row.tipo)
) for row in eachrow(df_loads))

lines = Dict(Symbol(row.branch) => (Rl=row.resistencia, Xl=row.X) for row in eachrow(df_lines))

# Matriz de incidencia
A = Dict()
line_conn = Dict()
for row in eachrow(df_lines)
    br = Symbol(row.branch)
    from_node = Symbol(row.from)
    to_node = Symbol(row.to)
    line_conn[br] = (from=from_node, to=to_node)
    A[(from_node, br)] = 1
    A[(to_node, br)] = -1
end

# ============================================
# FASE 1: OPF sin topología (Sistema original)
# ============================================
println("\n" * "="^50)
println("FASE 1: EJECUTANDO OPF SIN RECONFIGURACIÓN")
println("="^50)

model_original = Model(nl_solver)

# Variables por hora
@variable(model_original, VMIN <= v[k in nodes, h in horas] <= VMAX)
@variable(model_original, vr[k in nodes, h in horas])
@variable(model_original, vi[k in nodes, h in horas])
@variable(model_original, Ir[l in branches, h in horas])
@variable(model_original, Ii[l in branches, h in horas])
@variable(model_original, Pg[g in GENERADORES, h in horas] >= 0)
@variable(model_original, Qg[g in GENERADORES, h in horas])

# Variables para GD (se mantienen pero se fijan en 0, o no se crean si GD_ACTIVO=false)
if !GD_ACTIVO
    @variable(model_original, Pgd_original[k in nodes, h in horas] == 0)
    @variable(model_original, Qgd_original[k in nodes, h in horas] == 0)
    @variable(model_original, Qc_original[k in nodes, h in horas] == 0)
else
    @variable(model_original, Pgd_original[k in nodes, h in horas] >= 0)
    @variable(model_original, Qgd_original[k in nodes, h in horas])
    if COMP_CAP_ACTIVA
        @variable(model_original, Qc_original[k in nodes, h in horas] >= 0)
    else
        @variable(model_original, Qc_original[k in nodes, h in horas] == 0)
    end
end

# Slack bus
for h in horas
    fix(vr[SLACK_BUS, h], 1.0)
    fix(vi[SLACK_BUS, h], 0.0)
end

# Configurar tie-lines inicialmente desconectadas (solo en FASE 1)
for h in horas, l in branches
    if l in TIE_LINES
        fix(Ir[l, h], 0.0)
        fix(Ii[l, h], 0.0)
    end
end

# Objetivo: minimizar pérdidas totales
@objective(model_original, Min, sum(
    sum(lines[l].Rl * (Ir[l, h]^2 + Ii[l, h]^2) for l in branches) 
    for h in horas
))

# Restricciones por hora
for h in horas
    # Balance de potencias
    for k in nodes
        load_data = get(load_hourly, (k, h), (Pd=0.0, Qd=0.0))
        
        @constraint(model_original, 
            sum(Pg[g, h] for g in GENERADORES if map_gen_node[g] == k) + 
            Pgd_original[k, h] - load_data.Pd ==
            sum(get(A, (k, l), 0) * (vr[k, h] * Ir[l, h] + vi[k, h] * Ii[l, h]) for l in branches)
        )
        
        @constraint(model_original,
            sum(Qg[g, h] for g in GENERADORES if map_gen_node[g] == k) + 
            Qgd_original[k, h] + 
            Qc_original[k, h] - 
            load_data.Qd ==
            -sum(get(A, (k, l), 0) * (vr[k, h] * Ii[l, h] - vi[k, h] * Ir[l, h]) for l in branches)
        )
    end

    # Ecuaciones de corriente (para líneas no tie-lines)
    for l in branches
        if !(l in TIE_LINES)
            i, j = line_conn[l].from, line_conn[l].to
            R = lines[l].Rl
            X = lines[l].Xl
            den = R^2 + X^2
            
            @constraint(model_original, 
                Ir[l, h] == (R * (vr[i, h] - vr[j, h]) + X * (vi[i, h] - vi[j, h])) / den
            )
            @constraint(model_original,
                Ii[l, h] == (R * (vi[i, h] - vi[j, h]) - X * (vr[i, h] - vr[j, h])) / den
            )
        end
    end

    # Magnitud de voltaje
    for k in nodes
        @constraint(model_original, v[k, h]^2 == vr[k, h]^2 + vi[k, h]^2)
    end
end

println("Resolviendo FASE 1...")
optimize!(model_original)

if termination_status(model_original) ∉ [MOI.OPTIMAL, MOI.LOCALLY_SOLVED]
    error("FASE 1 falló: ", termination_status(model_original))
end

# Calcular resultados FASE 1
losses_hourly_original = Dict{Int, Float64}()

for h in horas
    hour_loss_pu = sum(lines[l].Rl * (value(Ir[l, h])^2 + value(Ii[l, h])^2) for l in branches)
    losses_hourly_original[h] = hour_loss_pu * SBASE_KVA
end

loss_pu_original = objective_value(model_original)
loss_kW_original = loss_pu_original * SBASE_KVA

println("\n✓ FASE 1 COMPLETADA")
println("  Pérdidas totales 24h: ", round(loss_kW_original, digits=2), " kW")
println("  Estado: ", termination_status(model_original))

# ============================================
# FASE 2: OPF con topología
# ============================================
println("\n" * "="^50)
println("FASE 2: EJECUTANDO OPF CON RECONFIGURACIÓN")
println("="^50)

model = Model(juniper_solver)

# Variables con inicialización desde FASE 1
@variable(model, VMIN <= v[k in nodes, h in horas] <= VMAX, start = value(v[k, h]))
@variable(model, vr[k in nodes, h in horas], start = value(vr[k, h]))
@variable(model, vi[k in nodes, h in horas], start = value(vi[k, h]))
@variable(model, Ir[l in branches, h in horas], start = value(Ir[l, h]))
@variable(model, Ii[l in branches, h in horas], start = value(Ii[l, h]))
@variable(model, Pg[g in GENERADORES, h in horas] >= 0, start = value(Pg[g, h]))
@variable(model, Qg[g in GENERADORES, h in horas], start = value(Qg[g, h]))

# Variables para GD (se mantienen pero se fijan en 0, o no se crean si GD_ACTIVO=false)
if !GD_ACTIVO
    @variable(model, Pgd[k in nodes, h in horas] == 0, start = 0)
    @variable(model, Qgd[k in nodes, h in horas] == 0, start = 0)
    @variable(model, Qc[k in nodes, h in horas] == 0, start = 0)
else
    @variable(model, Pgd[k in nodes, h in horas] >= 0, start = value(Pgd_original[k, h]))
    @variable(model, Qgd[k in nodes, h in horas], start = value(Qgd_original[k, h]))
    if COMP_CAP_ACTIVA
        @variable(model, Qc[k in nodes, h in horas] >= 0, start = value(Qc_original[k, h]))
    else
        @variable(model, Qc[k in nodes, h in horas] == 0, start = 0)
    end
end

# Variables de configuración
@variable(model, y[l in branches], Bin, start = l in TIE_LINES ? 0.0 : 1.0)

# Slack bus
for h in horas
    fix(vr[SLACK_BUS, h], 1.0)
    fix(vi[SLACK_BUS, h], 0.0)
end

# Objetivo
@objective(model, Min, sum(
    sum(lines[l].Rl * (Ir[l, h]^2 + Ii[l, h]^2) for l in branches) 
    for h in horas
))

# Restricciones por hora
for h in horas
    # Balance de potencias
    for k in nodes
        load_data = get(load_hourly, (k, h), (Pd=0.0, Qd=0.0))
        
        @constraint(model, 
            sum(Pg[g, h] for g in GENERADORES if map_gen_node[g] == k) + 
            Pgd[k, h] - load_data.Pd ==
            sum(get(A, (k, l), 0) * (vr[k, h] * Ir[l, h] + vi[k, h] * Ii[l, h]) for l in branches)
        )
        
        @constraint(model,
            sum(Qg[g, h] for g in GENERADORES if map_gen_node[g] == k) + 
            Qgd[k, h] + 
            Qc[k, h] - 
            load_data.Qd ==
            -sum(get(A, (k, l), 0) * (vr[k, h] * Ii[l, h] - vi[k, h] * Ir[l, h]) for l in branches)
        )
    end

    # Ecuaciones de corriente con topología (para todas las líneas)
    for l in branches
        i, j = line_conn[l].from, line_conn[l].to
        R = lines[l].Rl
        X = lines[l].Xl
        den = R^2 + X^2
        
        @constraint(model, 
            Ir[l, h] == y[l] * (R * (vr[i, h] - vr[j, h]) + X * (vi[i, h] - vi[j, h])) / den
        )
        @constraint(model,
            Ii[l, h] == y[l] * (R * (vi[i, h] - vi[j, h]) - X * (vr[i, h] - vr[j, h])) / den
        )
    end

    # Magnitud de voltaje
    for k in nodes
        @constraint(model, v[k, h]^2 == vr[k, h]^2 + vi[k, h]^2)
    end
end

# Restricción de radialidad
@constraint(model, nlines, sum(y[l] for l in branches) == length(nodes) - 1)

println("Resolviendo FASE 2...")
start_time = time()
optimize!(model)
solve_time = time() - start_time

# ============================================
# REPORTE DE RESULTADOS
# ============================================
if termination_status(model) in [MOI.OPTIMAL, MOI.LOCALLY_SOLVED]

    loss_pu = objective_value(model)
    loss_kW = loss_pu * SBASE_KVA
    
    # Calcular demanda total
    Pdemand_total_pu = 0.0
    demandas_horarias_kW = Float64[]
    for h in horas
        hour_demand_pu = 0.0
        for k in nodes
            if get(load_base, k, (Pd=0.0, Qd=0.0, tipo=:slack)).Pd > 0
                hour_demand_pu += load_hourly[(k, h)].Pd
            end
        end
        push!(demandas_horarias_kW, hour_demand_pu * SBASE_KVA)
        Pdemand_total_pu += hour_demand_pu
    end
    Pdemand_total_kW = Pdemand_total_pu * SBASE_KVA
    
    active_lines = [l for l in branches if value(y[l]) > 0.5]
    disconnected_lines = [l for l in branches if value(y[l]) < 0.5]

    println("\n" * "="^80)
    println("RESULTADOS FINALES - ESCENARIO $ESCENARIO")
    println("="^80)

    # CONFIGURACIÓN ÓPTIMA
    println("\nCONFIGURACIÓN ÓPTIMA DE RED:")
    println("  Líneas activas: ", join(active_lines, ", "))
    println("  Líneas desconectadas: ", join(disconnected_lines, ", "))
    println("  Tiempo de solución: ", round(solve_time, digits=2), " segundos")

    # DEMANDA POR HORA
    println("\n" * "="^50)
    println("DEMANDA POR HORA:")
    println("Hora | Demanda [kW]")
    println("-"^20)
    for h in horas
        println(rpad(h, 4), " | ", round(demandas_horarias_kW[h], digits=2))
    end
    println("-"^20)
    println(rpad("TOTAL", 4), " | ", round(Pdemand_total_kW, digits=2))

    # PÉRDIDAS COMPARATIVAS
    println("\n" * "="^50)
    println("PÉRDIDAS POR HORA - COMPARACIÓN:")
    println("Hora | Pérdidas [kW] Sin Reconf | Pérdidas [kW] Con Reconf | Reducción [kW] | Reducción [%]")
    println("-"^90)
    
    total_losses_kW_con = 0.0
    total_losses_kW_sin = 0.0
    
    for h in horas
        hour_loss_pu_con = sum(lines[l].Rl * (value(Ir[l, h])^2 + value(Ii[l, h])^2) for l in branches)
        hour_loss_kW_con = hour_loss_pu_con * SBASE_KVA
        total_losses_kW_con += hour_loss_kW_con
        
        hour_loss_kW_sin = losses_hourly_original[h]
        total_losses_kW_sin += hour_loss_kW_sin
        
        reduccion_kW = hour_loss_kW_sin - hour_loss_kW_con
        reduccion_percent = hour_loss_kW_sin > 0 ? (reduccion_kW / hour_loss_kW_sin) * 100 : 0.0
        
        println(rpad(h, 4), " | ", 
                rpad(round(hour_loss_kW_sin, digits=2), 21), " | ",
                rpad(round(hour_loss_kW_con, digits=2), 23), " | ",
                rpad(round(reduccion_kW, digits=2), 14), " | ",
                round(reduccion_percent, digits=2), "%")
    end
    
    reduccion_total_kW = total_losses_kW_sin - total_losses_kW_con
    reduccion_total_percent = (reduccion_total_kW / total_losses_kW_sin) * 100
    
    println("-"^90)
    println(rpad("TOTAL", 4), " | ", 
            rpad(round(total_losses_kW_sin, digits=2), 21), " | ",
            rpad(round(total_losses_kW_con, digits=2), 23), " | ",
            rpad(round(reduccion_total_kW, digits=2), 14), " | ",
            round(reduccion_total_percent, digits=2), "%")

    # RESUMEN FINAL
    reduccion_percentual = ((loss_kW_original - loss_kW) / loss_kW_original) * 100
    
    println("\n" * "="^80)
    println("RESUMEN COMPARATIVO - ESCENARIO $ESCENARIO")
    println("="^80)
    println("  Pérdidas sin reconfiguración (24h): ", round(loss_kW_original, digits=2), " kW")
    println("  Pérdidas con reconfiguración (24h): ", round(loss_kW, digits=2), " kW")
    println("  Reducción absoluta: ", round(loss_kW_original - loss_kW, digits=2), " kW")
    println("  Reducción porcentual: ", round(reduccion_percentual, digits=2), "%")
    println("  Demanda total 24h: ", round(Pdemand_total_kW, digits=2), " kW")
    println("  Estado del solver: ", termination_status(model))

    # VOLTAJES PROMEDIO
    println("\nVOLTAJES PROMEDIO EN 24 HORAS:")
    println("Nodo | Vmin [pu] | Vmax [pu] | Vavg [pu] | Tipo")
    println("-"^55)
    for k in nodes
        voltajes = [value(v[k, h]) for h in horas]
        v_min = minimum(voltajes)
        v_max = maximum(voltajes)
        v_avg = mean(voltajes)
        tipo_info = get(load_base, k, (Pd=0.0, Qd=0.0, tipo=:slack))
        tipo = tipo_info.tipo
        println(rpad(string(k), 4), " | ", 
                rpad(round(v_min, digits=4), 9), " | ",
                rpad(round(v_max, digits=4), 9), " | ",
                rpad(round(v_avg, digits=4), 9), " | ",
                tipo)
    end

else
    println("\n✗ SOLUCIÓN NO ÓPTIMA: ", termination_status(model))
end

println("\n" * "="^80)
println("SIMULACIÓN COMPLETADA - ESCENARIO $ESCENARIO")
println("="^80)


# ============================================
# ESCENARIO ESTÁTICO:
#   Reconfigurar usando SOLO la demanda de h=12 para elegir la topología,
#   fijarla y evaluar su efecto sobre las pérdidas en las 24 horas.
#   Luego se compara con el escenario dinámico (FASE 2).
# ============================================
println("\n" * "═"^64)
println("ESCENARIO ESTÁTICO: RECONFIGURACIÓN CON SOLO LA DEMANDA DE h=12")
println("═"^64)

h_pico = 12

# ---- Paso 1: elegir la topología estática resolviendo el MINLP solo en h=12 ----
model_static_minlp = Model(juniper_solver)

@variable(model_static_minlp, VMIN <= vs[k in nodes] <= VMAX)
@variable(model_static_minlp, vrs[k in nodes])
@variable(model_static_minlp, vis[k in nodes])
@variable(model_static_minlp, Irs[l in branches])
@variable(model_static_minlp, Iis[l in branches])
@variable(model_static_minlp, Pgs[g in GENERADORES] >= 0)
@variable(model_static_minlp, Qgs[g in GENERADORES])

if !GD_ACTIVO
    @variable(model_static_minlp, Pgds[k in nodes] == 0)
    @variable(model_static_minlp, Qgds[k in nodes] == 0)
    @variable(model_static_minlp, Qcs[k in nodes] == 0)
else
    @variable(model_static_minlp, Pgds[k in nodes] >= 0)
    @variable(model_static_minlp, Qgds[k in nodes])
    @variable(model_static_minlp, Qcs[k in nodes] == 0)
end

@variable(model_static_minlp, ys[l in branches], Bin, start = l in TIE_LINES ? 0.0 : 1.0)

fix(vrs[SLACK_BUS], 1.0)
fix(vis[SLACK_BUS], 0.0)

@objective(model_static_minlp, Min, sum(lines[l].Rl * (Irs[l]^2 + Iis[l]^2) for l in branches))

for k in nodes
    ld = load_hourly[(k, h_pico)]
    @constraint(model_static_minlp,
        sum(Pgs[g] for g in GENERADORES if map_gen_node[g] == k) + Pgds[k] - ld.Pd ==
        sum(get(A, (k, l), 0) * (vrs[k] * Irs[l] + vis[k] * Iis[l]) for l in branches))
    @constraint(model_static_minlp,
        sum(Qgs[g] for g in GENERADORES if map_gen_node[g] == k) + Qgds[k] + Qcs[k] - ld.Qd ==
        -sum(get(A, (k, l), 0) * (vrs[k] * Iis[l] - vis[k] * Irs[l]) for l in branches))
end

for l in branches
    i, j = line_conn[l].from, line_conn[l].to
    R = lines[l].Rl
    X = lines[l].Xl
    den = R^2 + X^2
    @constraint(model_static_minlp,
        Irs[l] == ys[l] * (R * (vrs[i] - vrs[j]) + X * (vis[i] - vis[j])) / den)
    @constraint(model_static_minlp,
        Iis[l] == ys[l] * (R * (vis[i] - vis[j]) - X * (vrs[i] - vrs[j])) / den)
end

for k in nodes
    @constraint(model_static_minlp, vs[k]^2 == vrs[k]^2 + vis[k]^2)
end

@constraint(model_static_minlp, sum(ys[l] for l in branches) == length(nodes) - 1)

println("Resolviendo MINLP estático (solo h=$h_pico)...")
optimize!(model_static_minlp)

if termination_status(model_static_minlp) ∉ [MOI.OPTIMAL, MOI.LOCALLY_SOLVED]
    error("MINLP estático falló: ", termination_status(model_static_minlp))
end

topologia_estatica = [l for l in branches if value(ys[l]) > 0.5]
lineas_apagadas_estatico = [l for l in branches if value(ys[l]) < 0.5]
println("  Topología estática (h=$h_pico): activas = ", join(topologia_estatica, ", "))
println("  Lin. desconectadas (estático) : ", join(lineas_apagadas_estatico, ", "))

# ---- Paso 2: evaluar la topología estática fija en las 24 horas (NLP) ----
model_static_24 = Model(nl_solver)

@variable(model_static_24, VMIN <= vs24[k in nodes, h in horas] <= VMAX, start = value(v[k, h]))
@variable(model_static_24, vrs24[k in nodes, h in horas], start = value(vr[k, h]))
@variable(model_static_24, vis24[k in nodes, h in horas], start = value(vi[k, h]))
@variable(model_static_24, Irs24[l in branches, h in horas], start = l in topologia_estatica ? value(Ir[l, h]) : 0.0)
@variable(model_static_24, Iis24[l in branches, h in horas], start = l in topologia_estatica ? value(Ii[l, h]) : 0.0)
@variable(model_static_24, Pgs24[g in GENERADORES, h in horas] >= 0, start = value(Pg[g, h]))
@variable(model_static_24, Qgs24[g in GENERADORES, h in horas], start = value(Qg[g, h]))

if !GD_ACTIVO
    @variable(model_static_24, Pgds24[k in nodes, h in horas] == 0, start = 0)
    @variable(model_static_24, Qgds24[k in nodes, h in horas] == 0, start = 0)
    @variable(model_static_24, Qcs24[k in nodes, h in horas] == 0, start = 0)
else
    @variable(model_static_24, Pgds24[k in nodes, h in horas] >= 0, start = 0)
    @variable(model_static_24, Qgds24[k in nodes, h in horas], start = 0)
    @variable(model_static_24, Qcs24[k in nodes, h in horas] == 0, start = 0)
end

for h in horas
    fix(vrs24[SLACK_BUS, h], 1.0)
    fix(vis24[SLACK_BUS, h], 0.0)
end

@objective(model_static_24, Min, sum(
    sum(lines[l].Rl * (Irs24[l, h]^2 + Iis24[l, h]^2) for l in branches) for h in horas
))

for h in horas
    for k in nodes
        ld = load_hourly[(k, h)]
        @constraint(model_static_24,
            sum(Pgs24[g, h] for g in GENERADORES if map_gen_node[g] == k) + Pgds24[k, h] - ld.Pd ==
            sum(get(A, (k, l), 0) * (vrs24[k, h] * Irs24[l, h] + vis24[k, h] * Iis24[l, h]) for l in branches))
        @constraint(model_static_24,
            sum(Qgs24[g, h] for g in GENERADORES if map_gen_node[g] == k) + Qgds24[k, h] + Qcs24[k, h] - ld.Qd ==
            -sum(get(A, (k, l), 0) * (vrs24[k, h] * Iis24[l, h] - vis24[k, h] * Irs24[l, h]) for l in branches))
    end

    for l in branches
        if l in topologia_estatica
            i, j = line_conn[l].from, line_conn[l].to
            R = lines[l].Rl
            X = lines[l].Xl
            den = R^2 + X^2
            @constraint(model_static_24,
                Irs24[l, h] == (R * (vrs24[i, h] - vrs24[j, h]) + X * (vis24[i, h] - vis24[j, h])) / den)
            @constraint(model_static_24,
                Iis24[l, h] == (R * (vis24[i, h] - vis24[j, h]) - X * (vrs24[i, h] - vrs24[j, h])) / den)
        else
            @constraint(model_static_24, Irs24[l, h] == 0)
            @constraint(model_static_24, Iis24[l, h] == 0)
        end
    end

    for k in nodes
        @constraint(model_static_24, vs24[k, h]^2 == vrs24[k, h]^2 + vis24[k, h]^2)
    end
end

println("Resolviendo evaluación de 24 h con la topología estática fija...")
optimize!(model_static_24)

if termination_status(model_static_24) ∉ [MOI.OPTIMAL, MOI.LOCALLY_SOLVED]
    error("Evaluación estática 24 h falló: ", termination_status(model_static_24))
end

losses_hourly_estatico = Dict{Int, Float64}()
for h in horas
    losses_hourly_estatico[h] = sum(lines[l].Rl * (value(Irs24[l, h])^2 + value(Iis24[l, h])^2) for l in branches) * SBASE_KVA
end

losses_hourly_dinamico = Dict{Int, Float64}()
for h in horas
    losses_hourly_dinamico[h] = sum(lines[l].Rl * (value(Ir[l, h])^2 + value(Ii[l, h])^2) for l in branches) * SBASE_KVA
end

loss_estatico_pu = objective_value(model_static_24)
loss_estatico_kWh = loss_estatico_pu * SBASE_KVA
reduccion_estatico_kWh = loss_kW_original - loss_estatico_kWh
reduccion_estatico_pct = (reduccion_estatico_kWh / loss_kW_original) * 100

loss_din_pu = sum(lines[l].Rl * (value(Ir[l, h])^2 + value(Ii[l, h])^2) for h in horas for l in branches)
loss_din_kWh = loss_din_pu * SBASE_KVA
reduccion_dinamico_kWh = loss_kW_original - loss_din_kWh
reduccion_dinamico_pct = (reduccion_dinamico_kWh / loss_kW_original) * 100

println("\n" * "="^80)
println("RESULTADO ESCENARIO ESTÁTICO (topología de h=12 evaluada en 24 h)")
println("="^80)
println("  Topología estática activas   : ", join(topologia_estatica, ", "))
println("  Lin. desconectadas (estático): ", join(lineas_apagadas_estatico, ", "))
println("  Pérdidas base (24 h)         : ", round(loss_kW_original, digits=2), " kWh")
println("  Pérdidas estáticas (24 h)    : ", round(loss_estatico_kWh, digits=2), " kWh")
println("  Reducción estática (24 h)    : ", round(reduccion_estatico_kWh, digits=2), " kWh  (", round(reduccion_estatico_pct, digits=2), " %)")
println("  Pérdidas dinámicas (24 h)    : ", round(loss_din_kWh, digits=2), " kWh")
println("  Reducción dinámica (24 h)    : ", round(reduccion_dinamico_kWh, digits=2), " kWh  (", round(reduccion_dinamico_pct, digits=2), " %)")
println("  Beneficio extra dinámico     : ", round(reduccion_dinamico_pct - reduccion_estatico_pct, digits=2), " puntos porcentuales")
println("═"^80)

println("\nPÉRDIDAS POR HORA - ESTÁTICO vs DINÁMICO vs BASE:")
println("Hora | Estático [kWh] | Dinámico [kWh] | Base [kWh] | Red. Estático [%] | Red. Dinámico [%]")
println("-"^95)
for h in horas
    b = losses_hourly_original[h]
    e = losses_hourly_estatico[h]
    d = losses_hourly_dinamico[h]
    re = b > 0 ? ((b - e) / b) * 100 : 0.0
    rd = b > 0 ? ((b - d) / b) * 100 : 0.0
    println(rpad(h, 4), " | ",
            rpad(round(e, digits=2), 15), " | ",
            rpad(round(d, digits=2), 15), " | ",
            rpad(round(b, digits=2), 12), " | ",
            rpad(round(re, digits=2), 19), " | ",
            round(rd, digits=2))
end
println("-"^95)

println("\n" * "═"^64)
println("ESCENARIO ESTÁTICO COMPLETADO")
println("═"^64)
