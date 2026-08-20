/*
 * OLAF-8: Bounded-Memory Online Adaptive Fuzzy Inference Engine
 * Tiny Tapeout SKY130 / Verilog
 * SPDX-License-Identifier: Apache-2.0
 *
 * Experimental area-optimization candidate.
 *
 * Preserved research mechanisms:
 *   - 8 bounded rule slots
 *   - 2-input fuzzy inference
 *   - fuzzy membership
 *   - MIN firing strength
 *   - firing-strength-gated online admission
 *   - least-utility rule replacement
 *   - shared streaming datapath
 *   - observable admission output
 *
 * Optimization organization:
 *   - packed 11-bit rule words
 *   - sequential least-utility search during the 8-rule scan
 *   - explicit membership truth tables
 *   - shift/add 4x4 product
 *   - bounded quotient engine (4-bit saturated output)
 *
 * IMPORTANT:
 * Cell count and timing must be confirmed by the actual Tiny Tapeout
 * synthesis/GDS flow. This file is a candidate, not a guaranteed
 * <=566-cell result.
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
     * Packed rule format:
     *
     * [10:9] antecedent 1
     * [ 8:7] antecedent 2
     * [ 6:3] consequent
     * [ 2:0] utility
     */
    reg [10:0] rule [0:7];

    reg [3:0] x1_r;
    reg [3:0] x2_r;

    reg [2:0] rule_idx;

    reg [3:0] max_fire;
    reg [2:0] max_idx;

    reg [2:0] min_util;
    reg [2:0] replace_idx;

    reg [10:0] sum_num;
    reg [6:0]  sum_den;

    /*
     * Bounded quotient state.
     *
     * We only expose a 4-bit saturated quotient. Therefore:
     *
     *   numerator / denominator >= 15  -> y = 15
     *
     * and at most 15 useful subtractions are required.
     */
    reg [10:0] q_num;
    reg [6:0]  q_den;
    reg [3:0]  q_count;
    reg [3:0]  q_value;

    /*
     * q_zero_den preserves the reference behavior:
     * output y = 0 for zero denominator, while an admitted rule
     * receives consequent 8.
     */
    reg q_zero_den;

    reg [1:0] state;

    localparam S_IDLE = 2'd0;
    localparam S_SCAN = 2'd1;
    localparam S_QUOT = 2'd2;


    // ============================================================
    // Exact finite membership tables
    // ============================================================

    function [3:0] memb;
        input [3:0] x;
        input [1:0] label;

        begin
            case (label)

                // LOW: max(0, 15 - 2*x)
                2'd0: begin
                    case (x)
                        4'd0: memb = 4'd15;
                        4'd1: memb = 4'd13;
                        4'd2: memb = 4'd11;
                        4'd3: memb = 4'd9;
                        4'd4: memb = 4'd7;
                        4'd5: memb = 4'd5;
                        4'd6: memb = 4'd3;
                        4'd7: memb = 4'd1;
                        default: memb = 4'd0;
                    endcase
                end

                // MID:
                // x<=7 : 2*x
                // x>7  : 30-2*x
                2'd1: begin
                    case (x)
                        4'd0:  memb = 4'd0;
                        4'd1:  memb = 4'd2;
                        4'd2:  memb = 4'd4;
                        4'd3:  memb = 4'd6;
                        4'd4:  memb = 4'd8;
                        4'd5:  memb = 4'd10;
                        4'd6:  memb = 4'd12;
                        4'd7:  memb = 4'd14;
                        4'd8:  memb = 4'd14;
                        4'd9:  memb = 4'd12;
                        4'd10: memb = 4'd10;
                        4'd11: memb = 4'd8;
                        4'd12: memb = 4'd6;
                        4'd13: memb = 4'd4;
                        4'd14: memb = 4'd2;
                        default: memb = 4'd0;
                    endcase
                end

                // HIGH: max(0, min(15, 2*(x-7)))
                default: begin
                    case (x)
                        4'd0:  memb = 4'd0;
                        4'd1:  memb = 4'd0;
                        4'd2:  memb = 4'd0;
                        4'd3:  memb = 4'd0;
                        4'd4:  memb = 4'd0;
                        4'd5:  memb = 4'd0;
                        4'd6:  memb = 4'd0;
                        4'd7:  memb = 4'd0;
                        4'd8:  memb = 4'd2;
                        4'd9:  memb = 4'd4;
                        4'd10: memb = 4'd6;
                        4'd11: memb = 4'd8;
                        4'd12: memb = 4'd10;
                        4'd13: memb = 4'd12;
                        4'd14: memb = 4'd14;
                        default: memb = 4'd15;
                    endcase
                end

            endcase
        end
    endfunction


    // ============================================================
    // Peak label
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
    // Current rule decode
    // ============================================================

    wire [1:0] cur_a1 = rule[rule_idx][10:9];
    wire [1:0] cur_a2 = rule[rule_idx][8:7];
    wire [3:0] cur_y  = rule[rule_idx][6:3];
    wire [2:0] cur_u  = rule[rule_idx][2:0];

    wire [3:0] cur_m1 = memb(x1_r, cur_a1);
    wire [3:0] cur_m2 = memb(x2_r, cur_a2);

    wire [3:0] cur_fire =
        (cur_m1 < cur_m2) ? cur_m1 : cur_m2;


    // ============================================================
    // 4x4 product using conditional shifts
    // ============================================================

    wire [7:0] prod0 =
        cur_fire[0] ? {4'b0000, cur_y} : 8'd0;

    wire [7:0] prod1 =
        cur_fire[1] ? {3'b000, cur_y, 1'b0} : 8'd0;

    wire [7:0] prod2 =
        cur_fire[2] ? {2'b00, cur_y, 2'b00} : 8'd0;

    wire [7:0] prod3 =
        cur_fire[3] ? {1'b0, cur_y, 3'b000} : 8'd0;

    wire [7:0] cur_prod =
        prod0 + prod1 + prod2 + prod3;


    // ============================================================
    // Final scan values
    // ============================================================

    wire [10:0] final_num =
        sum_num + {3'b000, cur_prod};

    wire [6:0] final_den =
        sum_den + {3'b000, cur_fire};

    wire [3:0] final_max_fire =
        (cur_fire > max_fire) ? cur_fire : max_fire;

    wire [2:0] final_max_idx =
        (cur_fire > max_fire) ? rule_idx : max_idx;


    // ============================================================
    // Bounded quotient next state
    // ============================================================

    wire q_can_sub =
        (q_num >= {4'b0000, q_den});

    wire [10:0] q_num_sub =
        q_num - {4'b0000, q_den};

    wire [3:0] q_value_sub =
        q_value + 4'd1;


    // ============================================================
    // Sequential controller
    // ============================================================

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            state       <= S_IDLE;

            y           <= 4'd8;
            done        <= 1'b0;
            admitted    <= 1'b0;
            busy        <= 1'b0;

            x1_r        <= 4'd0;
            x2_r        <= 4'd0;

            rule_idx    <= 3'd0;

            max_fire    <= 4'd0;
            max_idx     <= 3'd0;

            min_util    <= 3'd7;
            replace_idx <= 3'd0;

            sum_num     <= 11'd0;
            sum_den     <= 7'd0;

            q_num       <= 11'd0;
            q_den       <= 7'd1;
            q_count     <= 4'd0;
            q_value     <= 4'd0;
            q_zero_den  <= 1'b0;


            // ------------------------------------------------------
            // Same initial rule base as supplied baseline
            //
            // [a1][a2][y][u]
            // ------------------------------------------------------

            rule[0] <= 11'b00_00_0010_001;
            rule[1] <= 11'b00_01_0101_001;
            rule[2] <= 11'b00_10_0111_001;
            rule[3] <= 11'b01_00_0101_001;
            rule[4] <= 11'b01_01_1000_001;
            rule[5] <= 11'b01_10_1010_001;
            rule[6] <= 11'b10_00_0111_001;
            rule[7] <= 11'b10_10_1101_001;

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

                        min_util    <= 3'd7;
                        replace_idx <= 3'd0;

                        sum_num <= 11'd0;
                        sum_den <= 7'd0;

                        busy  <= 1'b1;
                        state <= S_SCAN;

                    end

                end


                // ==================================================
                // 8-cycle shared fuzzy scan
                // ==================================================

                S_SCAN: begin

                    busy <= 1'b1;

                    // Weighted numerator.
                    sum_num <= sum_num + {3'b000, cur_prod};

                    // Firing-strength denominator.
                    sum_den <= sum_den + {3'b000, cur_fire};

                    // Maximum firing rule.
                    if (cur_fire > max_fire) begin
                        max_fire <= cur_fire;
                        max_idx  <= rule_idx;
                    end

                    // Least-utility rule.
                    // Strict < preserves first minimum on ties.
                    if (cur_u < min_util) begin
                        min_util    <= cur_u;
                        replace_idx <= rule_idx;
                    end

                    if (rule_idx == 3'd7) begin

                        max_fire <= final_max_fire;
                        max_idx  <= final_max_idx;

                        /*
                         * Preserve reference behavior:
                         * denominator zero -> output 0, but an admitted
                         * rule receives consequent 8.
                         */
                        q_zero_den <= (final_den == 7'd0);

                        q_num <= final_num;

                        q_den <=
                            (final_den == 7'd0) ?
                            7'd1 :
                            final_den;

                        q_count <= 4'd0;
                        q_value <= 4'd0;

                        state <= S_QUOT;

                    end

                    else begin

                        rule_idx <= rule_idx + 3'd1;

                    end

                end


                // ==================================================
                // Saturating floor quotient
                // ==================================================

                S_QUOT: begin

                    busy <= 1'b1;

                    /*
                     * If denominator was zero, reference output is 0.
                     */
                    if (q_zero_den) begin

                        y <= 4'd0;

                        if (max_fire < ADMIT_THRESHOLD) begin

                            rule[replace_idx][10:9]
                                <= peak_label(x1_r);

                            rule[replace_idx][8:7]
                                <= peak_label(x2_r);

                            rule[replace_idx][6:3]
                                <= 4'd8;

                            rule[replace_idx][2:0]
                                <= 3'd4;

                            admitted <= 1'b1;

                        end

                        else if (rule[max_idx][2:0] != 3'd7) begin

                            rule[max_idx][2:0]
                                <= rule[max_idx][2:0] + 3'd1;

                        end

                        done  <= 1'b1;
                        busy  <= 1'b0;
                        state <= S_IDLE;

                    end

                    /*
                     * Saturate once quotient reaches 15.
                     */
                    else if (q_value == 4'd15) begin

                        y <= 4'd15;

                        if (max_fire < ADMIT_THRESHOLD) begin

                            rule[replace_idx][10:9]
                                <= peak_label(x1_r);

                            rule[replace_idx][8:7]
                                <= peak_label(x2_r);

                            rule[replace_idx][6:3]
                                <= 4'd15;

                            rule[replace_idx][2:0]
                                <= 3'd4;

                            admitted <= 1'b1;

                        end

                        else if (rule[max_idx][2:0] != 3'd7) begin

                            rule[max_idx][2:0]
                                <= rule[max_idx][2:0] + 3'd1;

                        end

                        done  <= 1'b1;
                        busy  <= 1'b0;
                        state <= S_IDLE;

                    end

                    /*
                     * Continue exact floor division while quotient < 15.
                     */
                    else if (q_can_sub) begin

                        q_num   <= q_num_sub;
                        q_value <= q_value_sub;
                        q_count <= q_count + 4'd1;

                    end

                    /*
                     * q_num < q_den => quotient is complete.
                     */
                    else begin

                        y <= q_value;

                        if (max_fire < ADMIT_THRESHOLD) begin

                            rule[replace_idx][10:9]
                                <= peak_label(x1_r);

                            rule[replace_idx][8:7]
                                <= peak_label(x2_r);

                            rule[replace_idx][6:3]
                                <= q_value;

                            rule[replace_idx][2:0]
                                <= 3'd4;

                            admitted <= 1'b1;

                        end

                        else if (rule[max_idx][2:0] != 3'd7) begin

                            rule[max_idx][2:0]
                                <= rule[max_idx][2:0] + 3'd1;

                        end

                        done  <= 1'b1;
                        busy  <= 1'b0;
                        state <= S_IDLE;

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
