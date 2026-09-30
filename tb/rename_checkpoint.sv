module rename_checkpoint_test;
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1, squash_valid = 0;
    logic [1:0] restore_cp_id = 0;
    logic [3:0] cp_release_mask = 0;
    logic [3:0] cp_alloc_id = 4'b0100;
    logic decode_valid = 0, disp_ready = 0;
    logic [233:0] decode_uop = 0;
    wire decode_ready, disp_valid;
    wire [1:0] cp_alloc_valid;

    rename dut (
        .clock, .reset, .squash_valid, .restore_cp_id, .cp_release_mask,
        .cp_free(3'd4), .cp_alloc_id, .decode_valid, .decode_ready,
        .decode_count(2'd2), .decode_uop,
        .rob_free(6'd32), .rob_tail(5'd0),
        .alu_iq_free(5'd16), .mem_iq_free(5'd16),
        .lq_free(4'd8), .sq_free(4'd8), .lq_alloc_id(6'b0), .sq_alloc_id(6'b0),
        .disp_valid, .disp_ready, .cp_alloc_valid,
        .wake_valid(2'b0), .wake_pdst(12'b0),
        .reg_commit_valid(2'b0), .reg_commit_payload(12'b0)
    );

    function automatic [116:0] uop(input [5:0] op, input [4:0] rd);
        uop = {32'd0, 32'd4, op, 5'd0, 5'd0, rd, 32'd4};
    endfunction
    task automatic tick;
        @(posedge clock);
        #1;
    endtask
    task automatic offer(input [116:0] first, second);
        @(negedge clock);
        if (!decode_ready) $fatal(1, "rename did not accept a new packet");
        decode_uop = {second, first};
        decode_valid = 1;
        tick();
        @(negedge clock) decode_valid = 0;
        tick();
        if (!disp_valid) $fatal(1, "rename did not form an offer");
    endtask

    initial begin
        tick();
        @(negedge clock) reset = 0;
        offer(uop(6'd3, 5'd1), uop(6'd20, 5'd2));
        repeat (3) tick();
        if (dut.snapshot_valid != 0 || cp_alloc_valid != 0 || dut.rat[1] != 1)
            $fatal(1, "preparing an image published speculative state before dispatch");
        if (dut.snapshot[0][1] != 32 || dut.snapshot[0][2] != 2)
            $fatal(1, "held offer checkpoint has the wrong lane boundary");
        @(negedge clock) disp_ready = 1;
        tick();
        if (!dut.snapshot_valid[0] || dut.rat[1] != 32 || dut.rat[2] != 33)
            $fatal(1, "dispatch did not publish the prepared image");
        @(negedge clock);
        disp_ready = 0;
        squash_valid = 1;
        cp_release_mask = 4'b0001;
        tick();
        if (dut.rat[1] != 32 || dut.rat[2] != 2 ||
            !dut.free_q[33] || dut.free_q[32])
            $fatal(1, "restore did not retain branch destination and reclaim younger destination");
        @(negedge clock);
        squash_valid = 0;
        cp_release_mask = 0;
        cp_alloc_id = 4'b1001;
        offer(uop(6'd3, 5'd3), uop(6'd3, 5'd4));
        tick();
        if (dut.snapshot[1][3] != 33 || dut.snapshot[1][4] != 4 ||
            dut.snapshot[2][3] != 33 || dut.snapshot[2][4] != 34)
            $fatal(1, "two branches did not get independent ordered images");
        @(negedge clock) disp_ready = 1;
        tick();
        @(negedge clock);
        disp_ready = 0;
        squash_valid = 1;
        restore_cp_id = 1;
        cp_release_mask = 4'b0110;
        tick();
        if (dut.rat[3] != 33 || dut.rat[4] != 4 || !dut.free_q[34])
            $fatal(1, "first branch restore kept second branch destination");
        $display("rename checkpoint preparation PASS");
        $finish;
    end
    initial begin
        #1000;
        $fatal(1, "rename checkpoint timeout");
    end
endmodule
