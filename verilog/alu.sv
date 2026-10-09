module alu #(
    parameter integer PIPELINED = 1,
    parameter integer EARLY_RESOLVE = 0, BRANCH_ISOLATE = 0,
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
    input wire resolve_exec_valid,
    input wire [31:0] branch_operand1, branch_operand2,
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

    wire immediate_op=in_op>=11 && in_op<=19;
    wire [31:0] operand_b=immediate_op?in_imm:b;
    wire is_left=in_op==17 || in_op==22;
    wire is_arithmetic=in_op==19 || in_op==27;
    wire [31:0] reversed_a;
    for (genvar bit_no=0; bit_no<32; bit_no=bit_no+1)
        assign reversed_a[bit_no]=a[31-bit_no];
    wire [31:0] shift_input=is_left?reversed_a:a;
    wire signed [32:0] shifted=$signed({is_arithmetic && a[31],shift_input}) >>> operand_b[4:0];
    wire [31:0] shift_value;
    for (genvar bit_no=0; bit_no<32; bit_no=bit_no+1)
        assign shift_value[bit_no]=is_left?shifted[31-bit_no]:shifted[bit_no];
    wire unsigned_less;
    (* keep_hierarchy, keep *) word_compare result_compare(
        .a(a), .b(operand_b), .less(unsigned_less), .equal());
    wire signed_less=(a[31]!=operand_b[31])?a[31]:unsigned_less;
    wire target_op=in_op==2;
    wire [31:0] add_a=(target_op && in_op!=4)?in_pc:a;
    wire [31:0] add_b=target_op?in_imm:operand_b;
    wire [31:0] add_value;
    (* keep_hierarchy, keep *) word_adder result_adder(
        .a(add_a), .b(in_op==21?~add_b:add_b), .carry_in(in_op==21), .sum(add_value));
    wire [31:0] branch_a=BRANCH_ISOLATE!=0?branch_operand1:a;
    wire [31:0] branch_b=BRANCH_ISOLATE!=0?branch_operand2:b;
    wire branch_unsigned_less, branch_equal;
    (* keep_hierarchy, keep *) word_compare branch_compare(
        .a(branch_a), .b(branch_b), .less(branch_unsigned_less), .equal(branch_equal));
    wire branch_signed_less=(branch_a[31]!=branch_b[31])?branch_a[31]:branch_unsigned_less;
    wire [31:0] branch_sum;
    (* keep_hierarchy, keep *) word_adder branch_adder(
        .a(in_op==4?branch_a:in_pc), .b(in_imm), .carry_in(1'b0), .sum(branch_sum));
    always_comb begin
        value=0; next_pc=in_pc+32'd4; control_flow=0; taken=0;
        target=(in_op==4)?(branch_sum & 32'hfffffffe):branch_sum;
        case (in_op)
            1: value=in_imm;
            2,11,20,21: value=add_value;
            3,4: begin control_flow=1; taken=1; value=in_pc+32'd4; end
            5: begin control_flow=1; taken=branch_equal; end
            6: begin control_flow=1; taken=!branch_equal; end
            7: begin control_flow=1; taken=branch_signed_less; end
            8: begin control_flow=1; taken=!branch_signed_less; end
            9: begin control_flow=1; taken=branch_unsigned_less; end
            10: begin control_flow=1; taken=!branch_unsigned_less; end
            12,23: value={31'd0,signed_less};
            13,24: value={31'd0,unsigned_less};
            14,25: value=a^operand_b;
            15,28: value=a|operand_b;
            16,29: value=a&operand_b;
            17,18,19,22,26,27: value=shift_value;
            default: value=0;
        endcase
        if (taken) next_pc=target;
    end

    assign exec_ready = !occupied || result_ready;
    // The single-issue datapath can forward the current ALU result directly.
    // Keep a skid register for WB stalls and keep resolution registered so
    // recovery never feeds back through its own execution/result selection.
    assign result_valid = occupied ||
        (PIPELINED == 0 && exec_valid && !incoming_young);
    assign result_payload = (PIPELINED == 0 && !occupied) ?
        {in_rob, in_pdst, value} : result_q;
    assign resolve_valid = EARLY_RESOLVE!=0 ? (resolve_exec_valid && control_flow && !reset) :
        (resolve_pending && (PIPELINED == 0 || occupied));
    assign resolve_payload = EARLY_RESOLVE!=0 ?
        {in_rob, in_cp, in_pc, (in_op>=5 && in_op<=10), taken, target, next_pc} : resolve_q;

    always_ff @(posedge clock) begin
        if (reset) begin
            occupied <= 0;
            resolve_pending <= 0;
        end else begin
            if (resolve_pending) resolve_pending <= 0;
            if (occupied && (result_ready || held_young)) occupied <= 0;
            if (exec_valid && exec_ready && !incoming_young) begin
                occupied <= PIPELINED != 0 || occupied || !result_ready;
                result_q <= {in_rob, in_pdst, value};
                resolve_q <= {in_rob, in_cp, in_pc, (in_op >= 5 && in_op <= 10),
                    taken, target, next_pc};
                resolve_pending <= control_flow;
            end
        end
    end
endmodule
