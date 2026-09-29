module decode #(
    parameter integer DISPATCH_WIDTH = 2,
    parameter integer DCW = $clog2(DISPATCH_WIDTH + 1),
    parameter integer FETCH_BITS = 96,
    parameter integer DECODE_BITS = 117
) (
    input logic fetch_valid,
    output logic fetch_ready,
    input logic [DCW-1:0] fetch_count,
    input logic [DISPATCH_WIDTH*FETCH_BITS-1:0] fetch_packet,
    output logic decode_valid,
    input logic decode_ready,
    output logic [DCW-1:0] decode_count,
    output logic [DISPATCH_WIDTH*DECODE_BITS-1:0] decode_uop
);
    assign decode_valid = fetch_valid;
    assign fetch_ready = decode_ready;
    assign decode_count = fetch_count;

    for (genvar lane = 0; lane < DISPATCH_WIDTH; lane = lane + 1) begin : g_decode
        wire [FETCH_BITS-1:0] packet = fetch_packet[lane*FETCH_BITS +: FETCH_BITS];
        wire [31:0] pc = packet[95:64];
        wire [31:0] inst = packet[63:32];
        wire [31:0] pred_npc = packet[31:0];
        wire [4:0] rd_field = inst[11:7];
        wire [4:0] rs1_field = inst[19:15];
        wire [4:0] rs2_field = inst[24:20];
        wire [31:0] imm_i = {{20{inst[31]}}, inst[31:20]};
        wire [31:0] imm_s = {{20{inst[31]}}, inst[31:25], inst[11:7]};
        wire [31:0] imm_b = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
        wire [31:0] imm_j = {{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};
        logic [5:0] op;
        logic [4:0] rs1, rs2, rd;
        logic [31:0] imm;
        always_comb begin
            op = 0;
            rs1 = 0;
            rs2 = 0;
            rd = 0;
            imm = 0;
            case (inst[6:0])
                7'b0110111: begin op = 1; rd = rd_field; imm = {inst[31:12], 12'b0}; end
                7'b0010111: begin op = 2; rd = rd_field; imm = {inst[31:12], 12'b0}; end
                7'b1101111: begin op = 3; rd = rd_field; imm = imm_j; end
                7'b1100111: if (inst[14:12] == 0) begin op = 4; rd = rd_field; rs1 = rs1_field; imm = imm_i; end
                7'b1100011: begin
                    case (inst[14:12])
                        3'b000: op = 5;
                        3'b001: op = 6;
                        3'b100: op = 7;
                        3'b101: op = 8;
                        3'b110: op = 9;
                        3'b111: op = 10;
                        default: op = 0;
                    endcase
                    if (op != 0) begin rs1 = rs1_field; rs2 = rs2_field; imm = imm_b; end
                end
                7'b0010011: begin
                    case (inst[14:12])
                        3'b000: op = 11;
                        3'b010: op = 12;
                        3'b011: op = 13;
                        3'b100: op = 14;
                        3'b110: op = 15;
                        3'b111: op = 16;
                        3'b001: if (inst[31:25] == 0) op = 17;
                        3'b101: begin
                            if (inst[31:25] == 0) op = 18;
                            else if (inst[31:25] == 7'b0100000) op = 19;
                        end
                        default: op = 0;
                    endcase
                    if (op != 0) begin rd = rd_field; rs1 = rs1_field; imm = imm_i; end
                end
                7'b0110011: begin
                    if (inst[31:25] == 7'b0000000) begin
                        case (inst[14:12])
                            3'b000: op = 20;
                            3'b001: op = 22;
                            3'b010: op = 23;
                            3'b011: op = 24;
                            3'b100: op = 25;
                            3'b101: op = 26;
                            3'b110: op = 28;
                            3'b111: op = 29;
                        endcase
                    end else if (inst[31:25] == 7'b0100000) begin
                        if (inst[14:12] == 3'b000) op = 21;
                        else if (inst[14:12] == 3'b101) op = 27;
                    end else if (inst[31:25] == 7'b0000001) begin
                        op = 6'd38 + {3'b0, inst[14:12]};
                    end
                    if (op != 0) begin rd = rd_field; rs1 = rs1_field; rs2 = rs2_field; end
                end
                7'b0000011: begin
                    case (inst[14:12])
                        3'b000: op = 30;
                        3'b001: op = 31;
                        3'b010: op = 32;
                        3'b100: op = 33;
                        3'b101: op = 34;
                        default: op = 0;
                    endcase
                    if (op != 0) begin rd = rd_field; rs1 = rs1_field; imm = imm_i; end
                end
                7'b0100011: begin
                    case (inst[14:12])
                        3'b000: op = 35;
                        3'b001: op = 36;
                        3'b010: op = 37;
                        default: op = 0;
                    endcase
                    if (op != 0) begin rs1 = rs1_field; rs2 = rs2_field; imm = imm_s; end
                end
                default: begin end
            endcase
        end
        assign decode_uop[lane*DECODE_BITS +: DECODE_BITS] = {pc, pred_npc, op, rs1, rs2, rd, imm};
    end
endmodule
