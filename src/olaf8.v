/*
 * OLAF-8: Bounded-Memory Online Adaptive Fuzzy Inference Engine
 * Tiny Tapeout SKY130 / Verilog
 * SPDX-License-Identifier: Apache-2.0
 *
 * 50%-TARGET EXPERIMENTAL ORGANIZATION
 *
 * Changes from the supplied 1,132-cell reference RTL:
 *   1. Rule fields are packed into one 11-bit word per slot.
 *   2. Least-utility search is performed during the existing 8-cycle scan.
 *   3. Defuzzification uses a bounded subtractive quotient engine.
 *
 * IMPORTANT:
 * This is an area-optimization candidate. The <=566-cell target
 * must be confirmed by the actual Tiny Tapeout synthesis/GDS flow.
 */

`default_nettype none

module tt_um_olaf8 (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    wire [3:0] y;
    wire       done;
    wire       admitted;
    wire       busy;

    olaf8_core core (
        .x1(ui_in[7:4]),
        .x2(ui_in[3:0]),
        .start(uio_in[0] & ena),
        .clk(clk),
        .rst_n(rst_n),
        .y(y),
        .done(done),
        .admitted(admitted),
        .busy(busy)
    );

    assign uo_out  = {1'b0, busy, admitted, done, y};
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

    wire _unused = &{1'b0, uio_in[7:1], 1'b0};

endmodule


module olaf8_core (
    input  wire [3:0] x1,
    input  wire [3:0] x2,
    input  wire       start,
    input  wire       clk,
    input  wire       rst_n,
    output reg  [3:0] y,
    output reg        done,
    output reg        admitted,
    output reg        busy
);

    localparam [3:0] ADMIT_THRESHOLD = 4'd6;

    /*
     * Packed rule:
     *
     *   rule_mem[i][10:9] = antecedent 1
     *   rule_mem[i][ 8:7] = antecedent 2
     *   rule_mem[i][ 6:3] = consequent
     *   rule_mem[i][ 2:0] = utility
     *
     * 11 bits/rule × 8 rules = 88 persistent bits.
     */
    reg [10:0] rule_mem [0:7];

    reg [3:0] x1_r;
    reg [3:0] x2_r;

    reg [2:0] rule_idx;

    reg [3:0] max_fire;
    reg [2:0] max_idx;

    /* Sequential least-utility selection. */
    reg [2:0] min_util_r;
    reg [2:0] min_idx_r;

    /*
     * Accumulation bounds:
     *
     * alpha <= 15
     * consequent <= 15
     * 8 rules
     *
     * numerator <= 8*15*15 = 1800
     * denominator <= 8*15 = 120
     *
     * 11 bits are therefore sufficient for numerator.
     * 7 bits are sufficient for denominator.
     */
    reg [10:0] sum_num;
    reg [6:0]  sum_den;

    /*
     * Bounded quotient engine.
     *
     * Output is only 4 bits and is saturated at 15.
     * For positive denominator, quotient values >=15 are
     * indistinguishable at the output. Therefore only 15
     * subtraction decisions are required.
     */
    reg [10:0] quot_num;
    reg [6:0]  quot_den;
    reg [3:0]  quot_count;
    reg [3:0]  quot_value;

    reg [1:0] state;

    localparam S_IDLE = 2'd0;
    localparam S_SCAN = 2'd1;
    localparam S_QUOT = 2'd2;


    // ============================================================
    // Membership
    // ============================================================

    function [3:0] memb;
        input [3:0] x;
        input [1:0] label;

        begin
            case (label)

                2'd0: begin
                    if (x <= 4'd7)
                        memb = 4'd15 - {x[2:0],1'b0};
                    else
                        memb = 4'd0;
                end

                2'd1: begin
                    if (x <= 4'd7)
                        memb = {x[2:0],1'b0};
                    else
                        memb = 5'd30 - {1'b0,x,1'b0};
                end

                default: begin
                    if (x < 4'd8)
                        memb = 4'd0;
                    else
                        memb = {1'b0,x} - 5'd7;
                end

            endcase
        end
    endfunction


    // ============================================================
    // Peak membership label
    // ============================================================

    function [1:0] peak_label;
        input [3:0] x;

        begin
            if (x <= 4'd3)
                peak_label = 2'd0;
            else if (x <= 4'd11)
                peak_label = 2'd1;
            else
                peak_label = 2'd2;
        end
    endfunction


    // ============================================================
    // Current packed rule fields
    // ============================================================

    wire [1:0] cur_a1 = rule_mem[rule_idx][10:9];
    wire [1:0] cur_a2 = rule_mem[rule_idx][8:7];
    wire [3:0] cur_y  = rule_mem[rule_idx][6:3];
    wire [2:0] cur_u  = rule_mem[rule_idx][2:0];

    wire [3:0] cur_m1 = memb(x1_r, cur_a1);
    wire [3:0] cur_m2 = memb(x2_r, cur_a2);

    wire [3:0] cur_fire =
        (cur_m1 < cur_m2) ? cur_m1 : cur_m2;

    wire [7:0] cur_prod =
        cur_fire * cur_y;


    // ============================================================
    // Final scan values
    // ============================================================

    wire [10:0] last_sum_num =
        sum_num + cur_prod;

    wire [6:0] last_sum_den =
        sum_den + cur_fire;

    wire [3:0] last_max_fire =
        (cur_fire > max_fire) ? cur_fire : max_fire;

    wire [2:0] last_max_idx =
        (cur_fire > max_fire) ? rule_idx : max_idx;


    // ============================================================
    // Bounded quotient comparison
    //
    // quotient = numerator / denominator
    //
    // We only need the quotient up to 15 because the output is
    // a 4-bit saturated value.
    // ============================================================

    wire quot_can_sub =
        (quot_num >= {4'd0, quot_den});

    wire [10:0] quot_num_next =
        quot_can_sub ?
        (quot_num - {4'd0, quot_den}) :
        quot_num;

    wire [3:0] quot_value_next =
        quot_can_sub ?
        (quot_value + 4'd1) :
        quot_value;


    // ============================================================
    // Main sequential process
    // ============================================================

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            state    <= S_IDLE;

            y        <= 4'd8;
            done     <= 1'b0;
            admitted <= 1'b0;
            busy     <= 1'b0;

            x1_r <= 4'd0;
            x2_r <= 4'd0;

            rule_idx <= 3'd0;

            max_fire <= 4'd0;
            max_idx  <= 3'd0;

            min_util_r <= 3'd7;
            min_idx_r  <= 3'd0;

            sum_num <= 11'd0;
            sum_den <= 7'd0;

            quot_num   <= 11'd0;
            quot_den   <= 7'd1;
            quot_count <= 4'd0;
            quot_value <= 4'd0;


            // ------------------------------------------------------
            // Same deterministic 8-rule initial rule base
            // ------------------------------------------------------

            rule_mem[0] <= 11'b00_00_0010_001;
            rule_mem[1] <= 11'b00_01_0101_001;
            rule_mem[2] <= 11'b00_10_0111_001;
            rule_mem[3] <= 11'b01_00_0101_001;
            rule_mem[4] <= 11'b01_01_1000_001;
            rule_mem[5] <= 11'b01_10_1010_001;
            rule_mem[6] <= 11'b10_00_0111_001;
            rule_mem[7] <= 11'b10_10_1101_001;

        end

        else begin

            done     <= 1'b0;
            admitted <= 1'b0;


            case (state)


                // ==================================================
                // IDLE
                // ==================================================

                S_IDLE: begin

                    busy <= 1'b0;

                    if (start) begin

                        x1_r <= x1;
                        x2_r <= x2;

                        rule_idx <= 3'd0;

                        max_fire <= 4'd0;
                        max_idx  <= 3'd0;

                        min_util_r <= 3'd7;
                        min_idx_r  <= 3'd0;

                        sum_num <= 11'd0;
                        sum_den <= 7'd0;

                        busy  <= 1'b1;
                        state <= S_SCAN;

                    end

                end


                // ==================================================
                // 8-RULE FUZZY SCAN
                // ==================================================

                S_SCAN: begin

                    busy <= 1'b1;


                    // Fuzzy weighted accumulation.
                    sum_num <= sum_num + cur_prod;
                    sum_den <= sum_den + cur_fire;


                    // Maximum firing strength.
                    if (cur_fire > max_fire) begin
                        max_fire <= cur_fire;
                        max_idx  <= rule_idx;
                    end


                    // Sequential least-utility search.
                    if (cur_u < min_util_r) begin
                        min_util_r <= cur_u;
                        min_idx_r  <= rule_idx;
                    end


                    if (rule_idx == 3'd7) begin

                        /*
                         * Start bounded quotient.
                         *
                         * If denominator is zero, use the same
                         * safe fallback behavior as the reference.
                         */
                        quot_num <= last_sum_num;

                        quot_den <=
                            (last_sum_den == 0) ?
                            7'd1 :
                            last_sum_den;

                        quot_count <= 4'd0;
                        quot_value <= 4'd0;

                        max_fire <= last_max_fire;
                        max_idx  <= last_max_idx;

                        state <= S_QUOT;

                    end

                    else begin

                        rule_idx <= rule_idx + 3'd1;

                    end

                end


                // ==================================================
                // BOUNDED DEFUZZIFICATION
                // ==================================================

                S_QUOT: begin

                    busy <= 1'b1;

                    /*
                     * Perform at most 15 useful subtraction steps.
                     *
                     * quotient >= 15 is saturated to 15, so no
                     * additional division iterations are necessary.
                     */

                    if (quot_count == 4'd15) begin

                        y <= quot_value;

                        // ------------------------------------------
                        // Firing-strength-gated admission
                        // ------------------------------------------

                        if (max_fire < ADMIT_THRESHOLD) begin

                            /*
                             * Pack the newly admitted rule into the
                             * selected least-utility slot.
                             */
                            rule_mem[min_idx_r][10:9]
                                <= peak_label(x1_r);

                            rule_mem[min_idx_r][8:7]
                                <= peak_label(x2_r);

                            rule_mem[min_idx_r][6:3]
                                <= quot_value;

                            rule_mem[min_idx_r][2:0]
                                <= 3'd4;

                            admitted <= 1'b1;

                        end

                        else begin

                            /*
                             * Increment winning-rule utility,
                             * saturating at 7.
                             */
                            if (rule_mem[max_idx][2:0] != 3'd7)
                                rule_mem[max_idx][2:0]
                                    <= rule_mem[max_idx][2:0] + 3'd1;

                        end

                        done  <= 1'b1;
                        busy  <= 1'b0;
                        state <= S_IDLE;

                    end

                    else begin

                        /*
                         * If numerator is already smaller than the
                         * denominator, the quotient is complete.
                         */
                        if (quot_num < {4'd0, quot_den}) begin

                            y <= quot_value;

                            if (max_fire < ADMIT_THRESHOLD) begin

                                rule_mem[min_idx_r][10:9]
                                    <= peak_label(x1_r);

                                rule_mem[min_idx_r][8:7]
                                    <= peak_label(x2_r);

                                rule_mem[min_idx_r][6:3]
                                    <= quot_value;

                                rule_mem[min_idx_r][2:0]
                                    <= 3'd4;

                                admitted <= 1'b1;

                            end

                            else begin

                                if (rule_mem[max_idx][2:0] != 3'd7)
                                    rule_mem[max_idx][2:0]
                                        <= rule_mem[max_idx][2:0] + 3'd1;

                            end

                            done  <= 1'b1;
                            busy  <= 1'b0;
                            state <= S_IDLE;

                        end

                        else begin

                            quot_num   <= quot_num_next;
                            quot_value <= quot_value_next;
                            quot_count <= quot_count + 4'd1;

                        end

                    end

                end


                default: begin
                    state <= S_IDLE;
                end

            endcase

        end

    end

endmodule

`default_nettype wire
