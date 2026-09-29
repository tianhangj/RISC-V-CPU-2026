module mul_div #(
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer TAG_BITS = RW,
    parameter integer MUL_EXEC_BITS = TAG_BITS + 3 + PW + 64,
    parameter integer RESULT_BITS = TAG_BITS + PW + 32
) (
    input logic clock, reset,
    input logic squash_valid,
    input logic [TAG_BITS-1:0] squash_tag,
    input logic [RW-1:0] rob_head,
    input logic exec_valid,
    output logic exec_ready,
    input logic [MUL_EXEC_BITS-1:0] exec_payload,
    output logic result_valid,
    input logic result_ready,
    output logic [RESULT_BITS-1:0] result_payload
);
    logic occupied;
    logic [RESULT_BITS-1:0] result_q;
    wire [TAG_BITS-1:0] in_rob = exec_payload[MUL_EXEC_BITS-1 -: TAG_BITS];
    wire [2:0] mul_op = exec_payload[64+PW+2 -: 3];
    wire [PW-1:0] pdst = exec_payload[64+PW-1 -: PW];
    wire [31:0] a = exec_payload[63:32];
    wire [31:0] b = exec_payload[31:0];
    wire signed [63:0] sa = {{32{a[31]}}, a};
    wire signed [63:0] sb = {{32{b[31]}}, b};
    wire signed [63:0] ub = {32'b0, b};
    wire [63:0] uu = a * b;
    wire signed [63:0] ss = sa * sb;
    wire signed [63:0] su = sa * ub;
    logic [31:0] value;
    wire [TAG_BITS-1:0] held_rob = result_q[RESULT_BITS-1 -: TAG_BITS];
    wire held_young = squash_valid && ((held_rob - rob_head) > (squash_tag - rob_head));
    wire incoming_young = squash_valid && ((in_rob - rob_head) > (squash_tag - rob_head));
    always_comb begin
        value = 0;
        case (mul_op)
            0: value = uu[31:0];
            1: value = ss[63:32];
            2: value = su[63:32];
            3: value = uu[63:32];
            4: begin
                if (b == 0) value = 32'hffffffff;
                else if (a == 32'h80000000 && b == 32'hffffffff) value = a;
                else value = $signed(a) / $signed(b);
            end
            5: value = (b == 0) ? 32'hffffffff : a / b;
            6: begin
                if (b == 0) value = a;
                else if (a == 32'h80000000 && b == 32'hffffffff) value = 0;
                else value = $signed(a) % $signed(b);
            end
            7: value = (b == 0) ? a : a % b;
        endcase
    end
    assign exec_ready = !occupied || result_ready;
    assign result_valid = occupied;
    assign result_payload = result_q;
    always_ff @(posedge clock) begin
        if (reset) occupied <= 0;
        else begin
            if (occupied && (result_ready || held_young)) occupied <= 0;
            if (exec_valid && exec_ready && !incoming_young) begin
                result_q <= {in_rob, pdst, value};
                occupied <= 1;
            end
        end
    end
endmodule
