// Simulation-only counters: this file is not part of verilog/filelist.f.
module ipc_stats_monitor (
    input wire clock, reset,
    input wire [31:0] issue_count, retire_count, dispatch_count,
    input wire [31:0] issue_limit,
    input wire any_candidate, fetch_starved, rename_blocked,
    input wire rob_full, alu_full, mem_full, cp_full, lsq_full,
    input wire head_store_wait, head_load_wait, squash,
    input wire dcache_miss, dcache_busy, store_hit, load_sent, cache_wait,
    input wire wb_conflict
);
    reg [63:0] cycles, issued, retired, dispatched, no_candidate, issue_blocked;
    reg [63:0] fetch_empty, rename_stall, rob_stall, alu_stall, mem_stall;
    reg [63:0] cp_stall, lsq_stall, store_head, load_head, mispredict;
    reg [63:0] cache_misses, cache_busy_cycles, store_hits, loads, cache_stall, wb_stall;
    always @(posedge clock) begin
        if (reset) begin
            cycles = 0; issued = 0; retired = 0; dispatched = 0;
            no_candidate = 0; issue_blocked = 0; fetch_empty = 0; rename_stall = 0;
            rob_stall = 0; alu_stall = 0; mem_stall = 0; cp_stall = 0; lsq_stall = 0;
            store_head = 0; load_head = 0; mispredict = 0; cache_misses = 0;
            cache_busy_cycles = 0; store_hits = 0; loads = 0; cache_stall = 0; wb_stall = 0;
        end else begin
            if (issue_count>issue_limit) $fatal(1,"CPU exceeded its configured issue width");
            cycles = cycles+1;
            issued = issued+64'(issue_count);
            retired = retired+64'(retire_count);
            dispatched = dispatched+64'(dispatch_count);
            if (issue_count == 0 && !any_candidate) no_candidate = no_candidate+1;
            if (issue_count == 0 && any_candidate) issue_blocked = issue_blocked+1;
            if (fetch_starved) fetch_empty = fetch_empty+1;
            if (rename_blocked) rename_stall = rename_stall+1;
            if (rob_full) rob_stall = rob_stall+1;
            if (alu_full) alu_stall = alu_stall+1;
            if (mem_full) mem_stall = mem_stall+1;
            if (cp_full) cp_stall = cp_stall+1;
            if (lsq_full) lsq_stall = lsq_stall+1;
            if (head_store_wait) store_head = store_head+1;
            if (head_load_wait) load_head = load_head+1;
            if (squash) mispredict = mispredict+1;
            if (dcache_miss) cache_misses = cache_misses+1;
            if (dcache_busy) cache_busy_cycles = cache_busy_cycles+1;
            if (store_hit) store_hits = store_hits+1;
            if (load_sent) loads = loads+1;
            if (cache_wait) cache_stall = cache_stall+1;
            if (wb_conflict) wb_stall = wb_stall+1;
        end
    end
    final begin
        $fdisplay(32'h80000002,
            "CPU2026 ipc_profile cycles=%0d issued=%0d retired=%0d dispatched=%0d no_candidate=%0d issue_blocked=%0d fetch_empty=%0d rename_stall=%0d rob_stall=%0d alu_stall=%0d mem_stall=%0d cp_stall=%0d lsq_stall=%0d store_head=%0d load_head=%0d mispredict=%0d cache_misses=%0d cache_busy_cycles=%0d store_hits=%0d loads=%0d cache_stall=%0d wb_stall=%0d",
            cycles, issued, retired, dispatched, no_candidate, issue_blocked,
            fetch_empty, rename_stall, rob_stall, alu_stall, mem_stall, cp_stall, lsq_stall,
            store_head, load_head, mispredict, cache_misses, cache_busy_cycles,
            store_hits, loads, cache_stall, wb_stall);
    end
endmodule

bind student_top ipc_stats_monitor u_ipc_stats (
    .clock(clock), .reset(reset),
    .issue_count(32'($countones(alu_cand_take))+32'(mem_cand_take)),
    .issue_limit(32'(ISSUE_WIDTH)),
    .retire_count(32'(u_rob.retire_count)),
    .dispatch_count(disp_fire ? 32'(disp_count) : 32'd0),
    .any_candidate((|alu_cand_valid) || mem_cand_valid),
    .fetch_starved(!fetch_valid && decode_ready),
    .rename_blocked(decode_valid && !decode_ready),
    .rob_full(rob_free == 0), .alu_full(alu_iq_free == 0), .mem_full(mem_iq_free == 0),
    .cp_full(cp_free == 0), .lsq_full(lq_free == 0 || sq_free == 0),
    .head_store_wait(u_rob.count_q != 0 && u_rob.alloc[rob_head][SIDW +: 2] == 3 &&
                     u_rob.retire_count == 0),
    .head_load_wait(u_rob.count_q != 0 && u_rob.alloc[rob_head][SIDW +: 2] == 2 &&
                    u_rob.retire_count == 0),
    .squash(squash_valid),
    .dcache_miss(u_dcache.state == 9 && !u_dcache.lookup_hit),
    .dcache_busy(u_dcache.state != 0 && u_dcache.state != 9),
    .store_hit(u_dcache.hit_store), .load_sent(ld_req_valid && ld_req_ready),
    .cache_wait(ld_req_valid && !ld_req_ready),
    .wb_conflict(32'($countones(alu_result_valid))+32'(mul_result_valid)+
                 32'(lsu_result_valid) > WB_WIDTH)
);
