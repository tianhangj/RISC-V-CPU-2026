module branch_ctrl #(
    parameter integer ROB_DEPTH = 32,
    parameter integer CHECKPOINT_DEPTH = 4,
    parameter integer GEN_WIDTH = 16
) (
    input logic clock, reset,
    input logic [RW-1:0] rob_head,
    output logic [GEN_WIDTH-1:0] current_gen,
    output logic [CCW-1:0] cp_free,
    output logic [CIDW-1:0] cp_alloc_id,
    input logic cp_alloc_valid,
    input logic [CP_ALLOC_BITS-1:0] cp_alloc_payload,
    input logic front_redirect_valid,
    input logic [31:0] front_redirect_pc,
    input logic resolve_valid,
    input logic [RESOLVE_BITS-1:0] resolve_payload,
    output logic train_valid,
    output logic [BP_TRAIN_BITS-1:0] train_payload,
    output logic [CHECKPOINT_DEPTH-1:0] cp_release_mask,
    output logic squash_valid,
    output logic [TAG_BITS-1:0] squash_tag,
    output logic [CIDW-1:0] restore_cp_id,
    output logic fetch_redirect_valid,
    output logic [FETCH_REDIRECT_BITS-1:0] fetch_redirect_payload
);
    localparam integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1;
    localparam integer CIDW = (CHECKPOINT_DEPTH > 1) ? $clog2(CHECKPOINT_DEPTH) : 1;
    localparam integer CCW = $clog2(CHECKPOINT_DEPTH + 1);
    localparam integer TAG_BITS = RW;
    localparam integer RESOLVE_BITS = TAG_BITS + CIDW + 98;
    localparam integer BP_TRAIN_BITS = 66;
    localparam integer CP_ALLOC_BITS = CIDW + TAG_BITS + 32;
    localparam integer FETCH_REDIRECT_BITS = 32 + GEN_WIDTH;
    logic [CHECKPOINT_DEPTH-1:0] cp_valid;
    logic [TAG_BITS-1:0] cp_tag [0:CHECKPOINT_DEPTH-1];
    logic [31:0] cp_pred_npc [0:CHECKPOINT_DEPTH-1];
    wire [CIDW-1:0] resolve_cp = resolve_payload[98 +: CIDW];
    wire [TAG_BITS-1:0] resolve_tag = resolve_payload[98+CIDW +: TAG_BITS];
    wire [31:0] resolve_npc = resolve_payload[31:0];
    wire matched = resolve_valid && resolve_cp < CHECKPOINT_DEPTH &&
        cp_valid[resolve_cp] && cp_tag[resolve_cp] == resolve_tag;
    wire surviving = matched;
    integer selected;
    function automatic [RW-1:0] age(input [TAG_BITS-1:0] tag);
        age = tag - rob_head;
    endfunction

    always_comb begin
        cp_free = 0;
        cp_alloc_id = 0;
        selected = -1;
        for (int c = 0; c < CHECKPOINT_DEPTH; c = c + 1) begin
            if (!cp_valid[c]) begin
                cp_free = cp_free + 1'b1;
                if (selected < 0) selected = c;
            end
        end
        if (selected >= 0) cp_alloc_id = CIDW'(selected);
    end

    // Identity and target preview do not depend on the recovery decision.
    assign squash_tag = resolve_tag;
    assign restore_cp_id = resolve_cp;
    assign squash_valid = matched && resolve_npc != cp_pred_npc[resolve_cp];
    assign train_valid = surviving;
    assign train_payload = surviving ? resolve_payload[32 +: BP_TRAIN_BITS] : 66'b0;
    assign fetch_redirect_valid = squash_valid || front_redirect_valid;
    assign fetch_redirect_payload = {
        squash_valid ? resolve_npc : front_redirect_pc, (current_gen + 1'b1)};

    always_comb begin
        cp_release_mask = 0;
        for (int c = 0; c < CHECKPOINT_DEPTH; c = c + 1)
            if (squash_valid && cp_valid[c] && age(cp_tag[c]) >= age(squash_tag))
                cp_release_mask[c] = 1;
        if (surviving) cp_release_mask[resolve_cp] = 1;
    end

    for (genvar c = 0; c < CHECKPOINT_DEPTH; c = c+1) begin : g_prepare_checkpoint
        always_ff @(posedge clock)
            if (!cp_valid[c] && cp_alloc_valid &&
                cp_alloc_payload[32+TAG_BITS +: CIDW] == CIDW'(c)) begin
                cp_tag[c] <= cp_alloc_payload[32 +: TAG_BITS];
                cp_pred_npc[c] <= cp_alloc_payload[31:0];
            end
    end
    always_ff @(posedge clock) begin
        if (reset) begin
            cp_valid <= 0;
            current_gen <= 0;
        end else begin
            if (fetch_redirect_valid) current_gen <= current_gen + 1'b1;
            for (int c = 0; c < CHECKPOINT_DEPTH; c = c + 1)
                if (cp_release_mask[c]) cp_valid[c] <= 0;
            if (!squash_valid && cp_alloc_valid)
                cp_valid[cp_alloc_payload[32+TAG_BITS +: CIDW]] <= 1;
        end
    end
endmodule
