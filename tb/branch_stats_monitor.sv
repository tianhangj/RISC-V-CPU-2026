// Simulation only: bind separately; never add this file to the synthesis filelist.
module branch_stats_monitor #(
    parameter integer ISSUE_WIDTH = 1,
    parameter integer CHECKPOINT_DEPTH = 4,
    parameter integer CIDW = 2,
    parameter integer RESOLVE_BITS = 105
) (
    input logic clock, reset,
    input logic [ISSUE_WIDTH-1:0] event_valid,
    input logic [ISSUE_WIDTH*RESOLVE_BITS-1:0] resolve_payload,
    input logic [31:0] predicted_npc [0:CHECKPOINT_DEPTH-1]
);
    typedef struct packed {
        logic [63:0] predictions;
        logic [63:0] correct;
        logic [63:0] taken;
        logic [63:0] taken_correct;
    } counts_t;
    // Include branch kind in the key, allowing code at a PC to change kind.
    counts_t counts [bit [32:0]];
    bit [32:0] key;
    logic [CIDW-1:0] cp;
    logic [31:0] actual_npc;
    logic taken, correct;
    always @(posedge clock) begin
        if (reset) counts.delete();
        else for (int lane = 0; lane < ISSUE_WIDTH; lane = lane+1)
            if (event_valid[lane]) begin
                key = {resolve_payload[lane*RESOLVE_BITS+66 +: 32],
                       resolve_payload[lane*RESOLVE_BITS+65]};
                cp = resolve_payload[lane*RESOLVE_BITS+98 +: CIDW];
                actual_npc = resolve_payload[lane*RESOLVE_BITS +: 32];
                taken = resolve_payload[lane*RESOLVE_BITS+64];
                if (cp >= CHECKPOINT_DEPTH) $fatal(1, "invalid statistics checkpoint");
                correct = predicted_npc[cp] == actual_npc;
                if (!counts.exists(key)) counts[key] = '0;
                counts[key].predictions = counts[key].predictions + 64'd1;
                if (correct) counts[key].correct = counts[key].correct + 64'd1;
                if (taken) begin
                    counts[key].taken = counts[key].taken + 64'd1;
                    if (correct) counts[key].taken_correct = counts[key].taken_correct + 64'd1;
                end
            end
    end
    final begin
        // stderr preserves the simulator's stdout/OJ result protocol.
        $fdisplay(32'h80000002, "CPU2026 branch_stats version=1 scope=resolved_next_pc");
        foreach (counts[pc_kind])
            $fdisplay(32'h80000002,
                "CPU2026 branch pc=0x%08x conditional=%0d predictions=%0d correct=%0d taken=%0d taken_correct=%0d",
                pc_kind[32:1], pc_kind[0], counts[pc_kind].predictions,
                counts[pc_kind].correct, counts[pc_kind].taken, counts[pc_kind].taken_correct);
        $fdisplay(32'h80000002, "CPU2026 branch_stats end=1");
    end
endmodule
