module alu #(
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer CHECKPOINT_DEPTH = 4,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer CIDW = (CHECKPOINT_DEPTH > 1) ? $clog2(CHECKPOINT_DEPTH) : 1,
    parameter integer TAG_BITS = RW,
    parameter integer ALU_EXEC_BITS = TAG_BITS + CIDW + 6 + PW + 128,
    parameter integer RESULT_BITS = TAG_BITS + PW + 32,
    parameter integer RESOLVE_BITS = TAG_BITS + CIDW + 98
) (
    input logic clock, reset,
    input logic squash_valid,
    input logic [TAG_BITS-1:0] squash_tag,
    input logic [RW-1:0] rob_head,
    input logic exec_valid,
    output logic exec_ready,
    input logic [ALU_EXEC_BITS-1:0] exec_payload,
    output logic result_valid,
    input logic result_ready,
    output logic [RESULT_BITS-1:0] result_payload,
    output logic resolve_valid,
    output logic [RESOLVE_BITS-1:0] resolve_payload
);
    logic occupied, resolve_pending;
    logic [RESULT_BITS-1:0] result_q;
    logic [RESOLVE_BITS-1:0] resolve_q;
    wire [TAG_BITS-1:0] in_rob = exec_payload[ALU_EXEC_BITS-1 -: TAG_BITS];
    wire [CIDW-1:0] in_cp = exec_payload[ALU_EXEC_BITS-TAG_BITS-1 -: CIDW];
    wire [5:0] in_op = exec_payload[128+PW+5 -: 6];
    wire [PW-1:0] in_pdst = exec_payload[128+PW-1 -: PW];
    wire [31:0] in_pc = exec_payload[127:96];
    wire [31:0] in_imm = exec_payload[95:64];
    wire [31:0] a = exec_payload[63:32];
    wire [31:0] b = exec_payload[31:0];
    wire [TAG_BITS-1:0] held_rob = result_q[RESULT_BITS-1 -: TAG_BITS];
    wire held_young = squash_valid && ((held_rob - rob_head) > (squash_tag - rob_head));
    wire incoming_young = squash_valid && ((in_rob - rob_head) > (squash_tag - rob_head));
    logic [31:0] value, next_pc, target;
    logic control_flow, taken;

    always_comb begin
        value = 0;
        next_pc = in_pc + 32'd4;
        control_flow = 0;
        taken = 0;
        target = in_pc + in_imm;
        case (in_op)
            1: value = in_imm;
            2: value = in_pc + in_imm;
            3: begin control_flow = 1; taken = 1; value = in_pc + 32'd4; end
            4: begin
                control_flow = 1; taken = 1; value = in_pc + 32'd4;
                target = (a + in_imm) & 32'hfffffffe;
            end
            5: begin control_flow = 1; taken = (a == b); end
            6: begin control_flow = 1; taken = (a != b); end
            7: begin control_flow = 1; taken = ($signed(a) < $signed(b)); end
            8: begin control_flow = 1; taken = ($signed(a) >= $signed(b)); end
            9: begin control_flow = 1; taken = (a < b); end
            10: begin control_flow = 1; taken = (a >= b); end
            11: value = a + in_imm;
            12: value = {31'b0, ($signed(a) < $signed(in_imm))};
            13: value = {31'b0, (a < in_imm)};
            14: value = a ^ in_imm;
            15: value = a | in_imm;
            16: value = a & in_imm;
            17: value = a << in_imm[4:0];
            18: value = a >> in_imm[4:0];
            19: value = $signed(a) >>> in_imm[4:0];
            20: value = a + b;
            21: value = a - b;
            22: value = a << b[4:0];
            23: value = {31'b0, ($signed(a) < $signed(b))};
            24: value = {31'b0, (a < b)};
            25: value = a ^ b;
            26: value = a >> b[4:0];
            27: value = $signed(a) >>> b[4:0];
            28: value = a | b;
            29: value = a & b;
            default: value = 0;
        endcase
        if (taken) next_pc = target;
    end

    assign exec_ready = !occupied || result_ready;
    assign result_valid = occupied;
    assign result_payload = result_q;
    assign resolve_valid = occupied && resolve_pending;
    assign resolve_payload = resolve_q;

    always_ff @(posedge clock) begin
        if (reset) begin
            occupied <= 0;
            resolve_pending <= 0;
        end else begin
            if (occupied && resolve_pending) resolve_pending <= 0;
            if (occupied && (result_ready || held_young)) occupied <= 0;
            if (exec_valid && exec_ready && !incoming_young) begin
                occupied <= 1;
                result_q <= {in_rob, in_pdst, value};
                resolve_q <= {in_rob, in_cp, in_pc, (in_op >= 5 && in_op <= 10),
                    taken, target, next_pc};
                resolve_pending <= control_flow;
            end
        end
    end
endmodule
