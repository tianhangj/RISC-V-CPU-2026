module prf_case #(
    parameter integer SIZE = 64,
    parameter integer BYPASS = 0,
    parameter integer PW = $clog2(SIZE)
) (output logic done);
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1;
    logic [4*PW-1:0] rd_addr = 0;
    wire [127:0] rd_data;
    logic [1:0] write_valid = 0;
    logic [2*PW-1:0] write_pdst = 0;
    logic [63:0] write_value = 0;
    logic forward_only = 0;
    logic [31:0] saved_nine;
    logic [31:0] expected [0:SIZE-1];

    prf #(.BYPASS_WRITE(BYPASS), .ISSUE_WIDTH(2), .WB_WIDTH(2), .PRF_SIZE(SIZE)) dut (
        .clock, .reset, .rd_addr, .rd_data,
        .write_valid, .write_pdst, .write_value,
        .forward_valid(forward_only ? 2'b01 : write_valid),
        .forward_pdst(forward_only ? {PW'(0), PW'(9)} : write_pdst),
        .forward_value(forward_only ? {32'd0, 32'h76543210} : write_value)
    );

    task automatic check_four(input integer first);
        integer index;
        logic [PW-1:0] addr0, addr1, addr2, addr3;
        begin
            addr0 = (first + 0) % SIZE;
            addr1 = (first + 1) % SIZE;
            addr2 = (first + 2) % SIZE;
            addr3 = (first + 3) % SIZE;
            rd_addr = {addr3, addr2, addr1, addr0};
            #1;
            for (integer lane = 0; lane < 4; lane = lane + 1) begin
                index = (first + lane) % SIZE;
                if (rd_data[lane*32 +: 32] !== expected[index]) begin
                    $fatal(1, "SIZE=%0d lane=%0d p%0d got=%h expected=%h",
                           SIZE, lane, index, rd_data[lane*32 +: 32], expected[index]);
                end
            end
        end
    endtask

    initial begin
        done = 0;
        expected[0] = 0;
        for (integer index = 1; index < 32; index = index + 1)
            expected[index] = 0;
        repeat (2) @(posedge clock);
        #1;
        check_four(0);
        check_four(28);

        @(negedge clock);
        reset = 0;
        for (integer index = 1; index < SIZE; index = index + 2) begin
            write_valid = (index + 1 < SIZE) ? 2'b11 : 2'b01;
            write_pdst[0 +: PW] = index;
            write_pdst[PW +: PW] = index + 1;
            write_value[0 +: 32] = 32'h12340000 ^ index;
            write_value[32 +: 32] = 32'habcd0000 ^ (index + 1);
            @(posedge clock);
            #1;
            expected[index] = write_value[0 +: 32];
            if (index + 1 < SIZE) expected[index + 1] = write_value[32 +: 32];
            @(negedge clock);
        end
        write_valid = 0;
        for (integer index = 0; index < SIZE; index = index + 4)
            check_four(index);

        // A completed producer can forward while it waits for a write port.
        // Removing that producer must reveal the unchanged stored value.
        forward_only = 1;
        saved_nine = expected[9];
        if (BYPASS) expected[9] = 32'h76543210;
        check_four(8);
        @(posedge clock);
        #1;
        check_four(8);
        @(negedge clock);
        forward_only = 0;
        expected[9] = saved_nine;
        check_four(8);

        write_valid = 2'b11;
        write_pdst[0 +: PW] = 8;
        write_pdst[PW +: PW] = 8;
        write_value = {32'hdeadbeef, 32'hcafebabe};
        if (BYPASS) expected[8] = 32'hdeadbeef;
        check_four(7);
        @(posedge clock);
        #1;
        expected[8] = 32'hdeadbeef;
        check_four(7);

        @(negedge clock);
        write_pdst[0 +: PW] = 0;
        write_pdst[PW +: PW] = SIZE - 1;
        write_value = {32'h89abcdef, 32'hffffffff};
        if (BYPASS) expected[SIZE-1] = 32'h89abcdef;
        check_four(0); // p0 must remain zero even during a matching write.
        check_four(SIZE-2);
        @(posedge clock);
        #1;
        expected[SIZE-1] = 32'h89abcdef;
        check_four(SIZE - 2);

        @(negedge clock);
        reset = 1;
        write_valid = 0;
        @(posedge clock);
        #1;
        for (integer index = 1; index < 32; index = index + 1)
            expected[index] = 0;
        for (integer index = 0; index < SIZE; index = index + 4)
            check_four(index);
        done = 1;
    end
endmodule

module prf_hierarchical_test;
    wire done64, done36, bypass64, bypass36;
    prf_case #(.SIZE(64)) case64 (.done(done64));
    prf_case #(.SIZE(36)) case36 (.done(done36));
    prf_case #(.SIZE(64), .BYPASS(1)) case_bypass64 (.done(bypass64));
    prf_case #(.SIZE(36), .BYPASS(1)) case_bypass36 (.done(bypass36));
    initial begin
        wait (done64 && done36 && bypass64 && bypass36);
        $display("prf hierarchical PASS");
        $finish;
    end
endmodule
