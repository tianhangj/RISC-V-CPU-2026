module predictor_case #(
    parameter integer WIDTH = 1,
    parameter integer ENABLE = 1
) (output logic done);
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1;
    logic [31:0] lookup_pc = 0;
    wire [WIDTH-1:0] pred_taken;
    wire [WIDTH*32-1:0] pred_npc;
    logic [WIDTH-1:0] train_valid = 0;
    logic [WIDTH*66-1:0] train_payload = 0;
    branch_predictor #(.DISPATCH_WIDTH(WIDTH), .ISSUE_WIDTH(WIDTH),
        .BTB_ENTRIES(4), .BHT_ENTRIES(8), .BP_ENABLE(ENABLE)) dut (.*);
    task automatic check(input [31:0] pc, input logic taken, input [31:0] npc);
        lookup_pc = pc;
        #1;
        if (pred_taken[0] !== (ENABLE != 0 && taken) ||
            pred_npc[31:0] !== (ENABLE != 0 ? npc : pc+32'd4))
            $fatal(1, "prediction pc=%h taken=%b npc=%h WIDTH=%0d ENABLE=%0d",
                pc, pred_taken[0], pred_npc[31:0], WIDTH, ENABLE);
    endtask
    task automatic train(input [31:0] pc, input logic conditional,
                         input logic taken, input [31:0] target);
        logic [WIDTH*33-1:0] saved_prediction;
        @(negedge clock);
        saved_prediction = {pred_taken, pred_npc};
        train_valid = 1;
        train_payload[65:0] = {pc, conditional, taken, target};
        // No write-to-lookup bypass before the update edge.
        #1;
        if ({pred_taken, pred_npc} !== saved_prediction)
            $fatal(1, "training bypassed the update edge");
        @(negedge clock) train_valid = 0;
    endtask
    initial begin
        done = 0;
        repeat (2) @(negedge clock);
        reset = 0;
        check(0, 0, 4);
        train(0, 1, 0, 100); // 01 -> 00; target must not become fall-through.
        check(0, 0, 4);
        train(0, 1, 0, 100); // saturate at 00
        train(0, 1, 1, 100); // 00 -> 01
        check(0, 0, 4);
        train(0, 1, 1, 100); // 01 -> 10
        check(0, 1, 100);
        train(0, 1, 1, 100); // 10 -> 11
        train(0, 1, 1, 100); // saturate at 11
        train(0, 1, 0, 100); // 11 -> 10
        check(0, 1, 100);
        train(0, 1, 0, 100); // 10 -> 01
        check(0, 0, 4);
        train(0, 1, 1, 4); // taken even though target == PC+4
        check(0, 1, 4);
        check(16, 0, 20); // same BTB index, different full tag
        train(16, 0, 1, 200);
        check(16, 1, 200);
        check(0, 0, 4); // replacement
        train(16, 0, 1, 204); // changing JALR target
        check(16, 1, 204);
        train(4, 0, 1, 300); // unconditional does not touch the BHT
        train(36, 1, 0, 400); // BHT alias, 01 -> 00
        train(4, 1, 1, 300); // 00 -> 01, still not taken
        check(4, 0, 8);
        train(4, 1, 1, 300);
        check(4, 1, 300);
        train(32'h10000000, 0, 1, 0);
        check(32'h10000000, 0, 32'h10000004); // non-RAM lookup
        if (WIDTH > 1) begin
            // At 11, T then N must produce 10, not 11 or 01.
            train(0, 1, 1, 100);
            @(negedge clock);
            train_valid = 0;
            train_valid[0] = 1;
            train_valid[1] = 1;
            train_payload[65:0] = {32'd0, 1'b1, 1'b1, 32'd100};
            train_payload[66 +: 66] = {32'd32, 1'b1, 1'b0, 32'd500};
            @(negedge clock) train_valid = 0;
            check(0, 0, 4); // younger BTB replacement wins
            check(32, 1, 500); // shared counter is 10
            train(32, 1, 0, 500);
            check(32, 0, 36); // 10 -> 01
        end
        if (WIDTH == 4) begin
            @(negedge clock);
            train_valid = 4'hf;
            train_payload[0 +: 66] = {32'd0, 1'b1, 1'b1, 32'd100};
            train_payload[66 +: 66] = {32'd32, 1'b1, 1'b1, 32'd200};
            train_payload[132 +: 66] = {32'd64, 1'b1, 1'b1, 32'd300};
            train_payload[198 +: 66] = {32'd96, 1'b1, 1'b0, 32'd600};
            @(negedge clock) train_valid = 0;
            check(96, 1, 600); // 01 -> 10 -> 11 -> 11 -> 10
            train(96, 1, 0, 600);
            check(96, 0, 100);
        end
        @(negedge clock) reset = 1;
        @(negedge clock) reset = 0;
        check(4, 0, 8);
        train(4, 1, 1, 300);
        check(4, 1, 300); // reset restored weak not-taken
        $display("PASS predictor WIDTH=%0d ENABLE=%0d", WIDTH, ENABLE);
        done = 1;
    end
endmodule

module branch_predictor_test;
    wire [3:0] done;
    predictor_case #(.WIDTH(1)) c0(done[0]);
    predictor_case #(.WIDTH(2)) c1(done[1]);
    predictor_case #(.WIDTH(4)) c2(done[2]);
    predictor_case #(.WIDTH(4), .ENABLE(0)) c3(done[3]);
    initial begin
        wait (&done);
        $finish;
    end
    initial begin
        #10000;
        $fatal(1, "predictor timeout");
    end
endmodule
