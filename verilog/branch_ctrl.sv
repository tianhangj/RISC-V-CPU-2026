module branch_ctrl #(
    parameter integer ISSUE_WIDTH = 2,
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer ROB_DEPTH = 32,
    parameter integer CHECKPOINT_DEPTH = 4,
    parameter integer GEN_WIDTH = 16,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer CIDW = (CHECKPOINT_DEPTH > 1) ? $clog2(CHECKPOINT_DEPTH) : 1,
    parameter integer CCW = $clog2(CHECKPOINT_DEPTH + 1),
    parameter integer TAG_BITS = RW,
    parameter integer RESOLVE_BITS = TAG_BITS + CIDW + 98,
    parameter integer BP_TRAIN_BITS = 66,
    parameter integer CP_ALLOC_BITS = CIDW + TAG_BITS + 32,
    parameter integer FETCH_REDIRECT_BITS = 32 + GEN_WIDTH
) (
    input logic clock, reset,
    input logic [RW-1:0] rob_head,
    output logic [GEN_WIDTH-1:0] current_gen,
    output logic [CCW-1:0] cp_free,
    output logic [DISPATCH_WIDTH*CIDW-1:0] cp_alloc_id,
    input logic [DISPATCH_WIDTH-1:0] cp_alloc_valid,
    input logic [DISPATCH_WIDTH*CP_ALLOC_BITS-1:0] cp_alloc_payload,
    input logic front_redirect_valid,
    input logic [31:0] front_redirect_pc,
    input logic [ISSUE_WIDTH-1:0] resolve_valid,
    input logic [ISSUE_WIDTH*RESOLVE_BITS-1:0] resolve_payload,
    output logic [ISSUE_WIDTH-1:0] train_valid,
    output logic [ISSUE_WIDTH*BP_TRAIN_BITS-1:0] train_payload,
    output logic [CHECKPOINT_DEPTH-1:0] cp_release_mask,
    output logic squash_valid,
    output logic [TAG_BITS-1:0] squash_tag,
    output logic [CIDW-1:0] restore_cp_id,
    output logic fetch_redirect_valid,
    output logic [FETCH_REDIRECT_BITS-1:0] fetch_redirect_payload
);
    logic [CHECKPOINT_DEPTH-1:0] cp_valid;
    logic [TAG_BITS-1:0] cp_tag [0:CHECKPOINT_DEPTH-1];
    logic [31:0] cp_pred_npc [0:CHECKPOINT_DEPTH-1];
    logic [ISSUE_WIDTH-1:0] matched;
    logic [CIDW-1:0] resolve_cp [0:ISSUE_WIDTH-1];
    logic [TAG_BITS-1:0] resolve_tag [0:ISSUE_WIDTH-1];
    logic [31:0] resolve_npc [0:ISSUE_WIDTH-1];
    logic [CHECKPOINT_DEPTH-1:0] preview_taken;
    integer selected, candidate, train_rank;
    logic [31:0] redirect_pc;
    logic [ISSUE_WIDTH-1:0] surviving;
    function automatic [RW-1:0] age(input [TAG_BITS-1:0] tag);
        age = tag - rob_head;
    endfunction
    always_comb begin
        cp_free = 0;
        cp_alloc_id = 0;
        preview_taken = 0;
        for (int c = 0; c < CHECKPOINT_DEPTH; c = c + 1)
            if (!cp_valid[c]) cp_free = cp_free + 1'b1;
        for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1) begin
            selected = -1;
            for (int c = 0; c < CHECKPOINT_DEPTH; c = c + 1)
                if (selected < 0 && !cp_valid[c] && !preview_taken[c]) selected = c;
            if (selected >= 0) begin
                cp_alloc_id[lane*CIDW +: CIDW] = selected;
                preview_taken[selected] = 1;
            end
        end
    end
    always_comb begin
        matched = 0;
        squash_valid = 0;
        squash_tag = 0;
        restore_cp_id = 0;
        redirect_pc = 0;
        cp_release_mask = 0;
        for (int lane = 0; lane < ISSUE_WIDTH; lane = lane + 1) begin
            resolve_cp[lane] = resolve_payload[lane*RESOLVE_BITS+98 +: CIDW];
            resolve_tag[lane] = resolve_payload[lane*RESOLVE_BITS+98+CIDW +: TAG_BITS];
            resolve_npc[lane] = resolve_payload[lane*RESOLVE_BITS +: 32];
            matched[lane] = resolve_valid[lane] && resolve_cp[lane] < CHECKPOINT_DEPTH &&
                cp_valid[resolve_cp[lane]] &&
                (cp_tag[resolve_cp[lane]] == resolve_tag[lane]);
            if (matched[lane] && resolve_npc[lane] != cp_pred_npc[resolve_cp[lane]] &&
                (!squash_valid || age(resolve_tag[lane]) < age(squash_tag))) begin
                squash_valid = 1;
                squash_tag = resolve_tag[lane];
                restore_cp_id = resolve_cp[lane];
                redirect_pc = resolve_npc[lane];
            end
        end
        for (int c = 0; c < CHECKPOINT_DEPTH; c = c + 1)
            if (squash_valid && cp_valid[c] &&
                age(cp_tag[c]) >= age(squash_tag))
                cp_release_mask[c] = 1;
        surviving = 0;
        for (int lane = 0; lane < ISSUE_WIDTH; lane = lane + 1) begin
            surviving[lane] = matched[lane] &&
                (!squash_valid || age(resolve_tag[lane]) <= age(squash_tag));
            if (surviving[lane])
                cp_release_mask[resolve_cp[lane]] = 1;
        end
        // Compact events in ROB age order, independent of ALU lane order.
        train_valid = 0;
        train_payload = 0;
        train_rank = 0;
        for (int lane = 0; lane < ISSUE_WIDTH; lane = lane + 1) begin
            train_rank = 0;
            for (int other = 0; other < ISSUE_WIDTH; other = other + 1)
                if (surviving[other] &&
                    (age(resolve_tag[other]) < age(resolve_tag[lane]) ||
                     (age(resolve_tag[other]) == age(resolve_tag[lane]) && other < lane)))
                    train_rank = train_rank + 1;
            if (surviving[lane]) begin
                train_valid[train_rank] = 1;
                train_payload[train_rank*BP_TRAIN_BITS +: BP_TRAIN_BITS] =
                    resolve_payload[lane*RESOLVE_BITS+32 +: BP_TRAIN_BITS];
            end
        end
        fetch_redirect_valid = squash_valid || front_redirect_valid;
        if (!squash_valid) redirect_pc = front_redirect_pc;
        fetch_redirect_payload = {redirect_pc, (current_gen + 1'b1)};
    end
    for (genvar c = 0; c < CHECKPOINT_DEPTH; c = c+1) begin : g_prepare_checkpoint
        always_ff @(posedge clock)
            if (!cp_valid[c])
                for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane+1)
                    if (cp_alloc_valid[lane] &&
                        cp_alloc_payload[lane*CP_ALLOC_BITS+32+TAG_BITS +: CIDW] == CIDW'(c)) begin
                        cp_tag[c] <= cp_alloc_payload[lane*CP_ALLOC_BITS+32 +: TAG_BITS];
                        cp_pred_npc[c] <= cp_alloc_payload[lane*CP_ALLOC_BITS +: 32];
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
            if (!squash_valid)
                for (int lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1)
                    if (cp_alloc_valid[lane]) begin
                        candidate = cp_alloc_payload[lane*CP_ALLOC_BITS+32+TAG_BITS +: CIDW];
                        cp_valid[candidate] <= 1;
                    end
        end
    end
endmodule
