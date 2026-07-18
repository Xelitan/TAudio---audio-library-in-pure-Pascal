{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
unit LameMDCT;

//  LAME MP3 Encoder - Free Pascal translation, only CBR
//  License: GNU LGPL
//  Author: www.xelitan.com
//  Polyphase filterbank and MDCT
//  Translated from newmdct.c


interface

uses LameTypes, Math;

{ Main MDCT entry point: polyphase filter + MDCT for all granules/channels }
procedure mdct_sub48(gfc: PLameInternalFlags;
                     const w0: PSample; const w1: PSample);

{ Initialize enwindow table (call once at startup) }
procedure init_enwindow;

implementation

{$POINTERMATH ON}

const
  NS = 12;
  NL = 36;

  { MDCT window coefficients: win[block_type][0..35] }
  win: array[0..3, 0..NL - 1] of TFloat = (
    ( { NORM_TYPE }
     2.382191739347913e-13, 6.423305872147834e-13, 9.400849094049688e-13,
     1.122435026096556e-12, 1.183840321267481e-12, 1.122435026096556e-12,
     9.400849094049690e-13, 6.423305872147839e-13, 2.382191739347918e-13,
     5.456116108943412e-12, 4.878985199565852e-12, 4.240448995017367e-12,
     3.559909094758252e-12, 2.858043359288075e-12, 2.156177623817898e-12,
     1.475637723558783e-12, 8.371015190102974e-13, 2.599706096327376e-13,
    -5.456116108943412e-12,-4.878985199565852e-12,-4.240448995017367e-12,
    -3.559909094758252e-12,-2.858043359288076e-12,-2.156177623817898e-12,
    -1.475637723558783e-12,-8.371015190102975e-13,-2.599706096327376e-13,
    -2.382191739347923e-13,-6.423305872147843e-13,-9.400849094049696e-13,
    -1.122435026096556e-12,-1.183840321267481e-12,-1.122435026096556e-12,
    -9.400849094049694e-13,-6.423305872147840e-13,-2.382191739347918e-13),
    ( { START_TYPE }
     2.382191739347913e-13, 6.423305872147834e-13, 9.400849094049688e-13,
     1.122435026096556e-12, 1.183840321267481e-12, 1.122435026096556e-12,
     9.400849094049688e-13, 6.423305872147841e-13, 2.382191739347918e-13,
     5.456116108943413e-12, 4.878985199565852e-12, 4.240448995017367e-12,
     3.559909094758253e-12, 2.858043359288075e-12, 2.156177623817898e-12,
     1.475637723558782e-12, 8.371015190102975e-13, 2.599706096327376e-13,
    -5.461314069809755e-12,-4.921085770524055e-12,-4.343405037091838e-12,
    -3.732668368707687e-12,-3.093523840190885e-12,-2.430835727329465e-12,
    -1.734679010007751e-12,-9.748253656609281e-13,-2.797435120168326e-13,
     0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    -2.283748241799531e-13,-4.037858874020686e-13,-2.146547464825323e-13),
    ( { SHORT_TYPE: win, tantab_l, cx, ca, cs packed }
     1.316524975873958e-01, 4.142135623730950e-01, 7.673269879789602e-01,
     1.091308501069271e+00, 1.303225372841206e+00, 1.569685577117490e+00,
     1.920982126971166e+00, 2.414213562373094e+00, 3.171594802363212e+00,
     4.510708503662055e+00, 7.595754112725146e+00, 2.290376554843115e+01,
     0.98480775301220802032, 0.64278760968653936292, 0.34202014332566882393,
     0.93969262078590842791,-0.17364817766693030343,-0.76604444311897790243,
     0.86602540378443870761, 0.500000000000000e+00,
    -5.144957554275265e-01,-4.717319685649723e-01,-3.133774542039019e-01,
    -1.819131996109812e-01,-9.457419252642064e-02,-4.096558288530405e-02,
    -1.419856857247115e-02,-3.699974673760037e-03,
     8.574929257125442e-01, 8.817419973177052e-01, 9.496286491027329e-01,
     9.833145924917901e-01, 9.955178160675857e-01, 9.991605581781475e-01,
     9.998991952444470e-01, 9.999931550702802e-01),
    ( { STOP_TYPE }
     0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
     2.283748241799531e-13, 4.037858874020686e-13, 2.146547464825323e-13,
     5.461314069809755e-12, 4.921085770524055e-12, 4.343405037091838e-12,
     3.732668368707687e-12, 3.093523840190885e-12, 2.430835727329466e-12,
     1.734679010007751e-12, 9.748253656609281e-13, 2.797435120168326e-13,
    -5.456116108943413e-12,-4.878985199565852e-12,-4.240448995017367e-12,
    -3.559909094758253e-12,-2.858043359288075e-12,-2.156177623817898e-12,
    -1.475637723558782e-12,-8.371015190102975e-13,-2.599706096327376e-13,
    -2.382191739347913e-13,-6.423305872147834e-13,-9.400849094049688e-13,
    -1.122435026096556e-12,-1.183840321267481e-12,-1.122435026096556e-12,
    -9.400849094049688e-13,-6.423305872147841e-13,-2.382191739347918e-13)
  );

  { Subband reordering table }
  order: array[0..31] of Integer = (
    0,1,16,17,8,9,24,25,4,5,20,21,12,13,28,29,
    2,3,18,19,10,11,26,27,6,7,22,23,14,15,30,31
  );

var
  { Polyphase filter coefficients, initialized at startup }
  enwindow: array[0..287] of TFloat;

{ Pointers into win[SHORT_TYPE] for MDCT constants }
{ tantab_l = win[SHORT_TYPE][3..11] }
{ cx       = win[SHORT_TYPE][12..19] }
{ ca       = win[SHORT_TYPE][20..27] }
{ cs       = win[SHORT_TYPE][28..35] }

procedure init_enwindow;
const
  INV = 1.0 / 2.384e-6;

  { Group multipliers }
  M: array[0..14] of Double = (
    0.740951125354959, 0.773010453362737, 0.803207531480645,
    0.831469612302545, 0.857728610000272, 0.881921264348355,
    0.903989293123443, 0.92387953251128675613, 0.941544065183021,
    0.956940335732209, 0.970031253194544, 0.98078528040323,
    0.989176509964781, 0.995184726672197, 0.998795456205172
  );

  { Raw filter values (before scaling), x2 side (8 per group) }
  raw_x2: array[0..14, 0..7] of Double = (
    (-4.77e-07,  1.03951e-04,  9.53674e-04,  2.841473e-03,
      3.5758972e-02, 3.401756e-03, 9.83715e-04, 9.9182e-05),
    (-4.77e-07,  1.05858e-04,  9.30786e-04,  2.521515e-03,
      3.5694122e-02, 3.643036e-03, 9.91821e-04, 9.6321e-05),
    (-4.77e-07,  1.07288e-04,  9.02653e-04,  2.174854e-03,
      3.5586357e-02, 3.858566e-03, 9.95159e-04, 9.3460e-05),
    (-4.77e-07,  1.08242e-04,  8.68797e-04,  1.800537e-03,
      3.5435200e-02, 4.049301e-03, 9.94205e-04, 9.0599e-05),
    (-4.77e-07,  1.08719e-04,  8.29220e-04,  1.399517e-03,
      3.5242081e-02, 4.215240e-03, 9.89437e-04, 8.7261e-05),
    (-4.77e-07,  1.08719e-04,  7.8392e-04,   9.71317e-04,
      3.5007000e-02, 4.357815e-03, 9.80854e-04, 8.3923e-05),
    (-9.54e-07,  1.08242e-04,  7.31945e-04,  5.15938e-04,
      3.4730434e-02, 4.477024e-03, 9.68933e-04, 8.0585e-05),
    (-9.54e-07,  1.06812e-04,  6.74248e-04,  3.3379e-05,
      3.4412861e-02, 4.573822e-03, 9.54151e-04, 7.6771e-05),
    (-9.54e-07,  1.05381e-04,  6.10352e-04, -4.75883e-04,
      3.4055710e-02, 4.649162e-03, 9.35555e-04, 7.3433e-05),
    (-9.54e-07,  1.02520e-04,  5.39303e-04, -1.011848e-03,
      3.3659935e-02, 4.703045e-03, 9.15051e-04, 7.0095e-05),
    (-1.431e-06, 9.9182e-05,   4.62532e-04, -1.573563e-03,
      3.3225536e-02, 4.737377e-03, 8.91685e-04, 6.6280e-05),
    (-1.431e-06, 9.5367e-05,   3.78609e-04, -2.161503e-03,
      3.2754898e-02, 4.752159e-03, 8.66413e-04, 6.2943e-05),
    (-1.907e-06, 9.0122e-05,   2.88486e-04, -2.774239e-03,
      3.2248020e-02, 4.748821e-03, 8.38757e-04, 5.9605e-05),
    (-1.907e-06, 8.4400e-05,   1.91689e-04, -3.411293e-03,
      3.1706810e-02, 4.728317e-03, 8.09669e-04, 5.579e-05),
    (-2.384e-06, 7.7724e-05,   8.8215e-05,  -4.072189e-03,
      3.1132698e-02, 4.691124e-03, 7.79152e-04, 5.2929e-05)
  );

  { Raw filter values, x1 side (8 per group) }
  raw_x1: array[0..14, 0..7] of Double = (
    (1.2398e-05,  1.91212e-04, 2.283096e-03, 1.6994476e-02,
    -1.8756866e-02,-2.630711e-03,-2.47478e-04,-1.4782e-05),
    (1.1444e-05,  1.65462e-04, 2.110004e-03, 1.6112804e-02,
    -1.9634247e-02,-2.803326e-03,-2.77042e-04,-1.6689e-05),
    (1.0014e-05,  1.40190e-04, 1.937389e-03, 1.5233517e-02,
    -2.0506859e-02,-2.974033e-03,-3.07560e-04,-1.8120e-05),
    (9.060e-06,   1.16348e-04, 1.766682e-03, 1.4358521e-02,
    -2.1372318e-02,-3.14188e-03,-3.39031e-04,-1.9550e-05),
    (8.106e-06,   9.3937e-05,  1.597881e-03, 1.3489246e-02,
    -2.2228718e-02,-3.306866e-03,-3.71456e-04,-2.1458e-05),
    (7.629e-06,   7.2956e-05,  1.432419e-03, 1.2627602e-02,
    -2.3074150e-02,-3.467083e-03,-4.04358e-04,-2.3365e-05),
    (6.676e-06,   5.2929e-05,  1.269817e-03, 1.1775017e-02,
    -2.3907185e-02,-3.622532e-03,-4.38213e-04,-2.5272e-05),
    (6.199e-06,   3.4332e-05,  1.111031e-03, 1.0933399e-02,
    -2.4725437e-02,-3.771782e-03,-4.72546e-04,-2.7657e-05),
    (5.245e-06,   1.7166e-05,  9.56535e-04,  1.0103703e-02,
    -2.5527000e-02,-3.914356e-03,-5.07355e-04,-3.0041e-05),
    (4.768e-06,   9.54e-07,    8.06808e-04,  9.287834e-03,
    -2.6310921e-02,-4.048824e-03,-5.42164e-04,-3.2425e-05),
    (4.292e-06,  -1.3828e-05,  6.61850e-04,  8.487225e-03,
    -2.7073860e-02,-4.174709e-03,-5.76973e-04,-3.4809e-05),
    (3.815e-06,  -2.718e-05,   5.22137e-04,  7.703304e-03,
    -2.7815342e-02,-4.290581e-03,-6.11782e-04,-3.7670e-05),
    (3.338e-06,  -3.9577e-05,  3.88145e-04,  6.937027e-03,
    -2.8532982e-02,-4.395962e-03,-6.46591e-04,-4.0531e-05),
    (3.338e-06,  -5.0545e-05,  2.59876e-04,  6.189346e-03,
    -2.9224873e-02,-4.489899e-03,-6.80923e-04,-4.3392e-05),
    (2.861e-06,  -6.0558e-05,  1.37329e-04,  5.462170e-03,
    -2.9890060e-02,-4.570484e-03,-7.14302e-04,-4.6253e-05)
  );

  { Tangent/cosine values at index 16,17 of each group }
  tan_vals: array[0..14, 0..1] of Double = (
    (9.063471690191471e-01, 1.960342806591213e-01),
    (8.206787908286602e-01, 3.901806440322567e-01),
    (7.416505462720353e-01, 5.805693545089249e-01),
    (6.681786379192989e-01, 7.653668647301797e-01),
    (5.993769336819237e-01, 9.427934736519954e-01),
    (5.345111359507916e-01, 1.111140466039205e+00),
    (4.729647758913199e-01, 1.268786568327291e+00),
    (4.1421356237309504879e-01, 1.414213562373095e+00),
    (3.578057213145241e-01, 1.546020906725474e+00),
    (3.033466836073424e-01, 1.662939224605090e+00),
    (2.504869601913055e-01, 1.763842528696710e+00),
    (1.989123673796580e-01, 1.847759065022573e+00),
    (1.483359875383474e-01, 1.913880671464418e+00),
    (9.849140335716425e-02, 1.961570560806461e+00),
    (4.912684976946725e-02, 1.990369453344394e+00)
  );

  S2H = 1.41421356237309504880 * 0.5 / 2.384e-6;
var
  i, j, base: Integer;
  mscale: Double;
begin
  { Fill main loop groups (15 groups × 18 = 270 elements) }
  for i := 0 to 14 do
  begin
    base := i * 18;
    mscale := M[i] * INV;
    { x2 side: 8 values }
    for j := 0 to 7 do
      enwindow[base + j] := raw_x2[i][j] * mscale;
    { x1 side: 8 values }
    for j := 0 to 7 do
      enwindow[base + 8 + j] := raw_x1[i][j] * mscale;
    { tangent/cosine values }
    enwindow[base + 16] := tan_vals[i][0];
    enwindow[base + 17] := tan_vals[i][1];
  end;

  { Final group (i=0 special case): indices 270..287 }
  { First 8: SQRT2*0.5 scaled values }
  enwindow[270] :=  3.5780907e-02 * S2H;
  enwindow[271] :=  1.7876148e-02 * S2H;
  enwindow[272] :=  3.134727e-03  * S2H;
  enwindow[273] :=  2.457142e-03  * S2H;
  enwindow[274] :=  9.71317e-04   * S2H;
  enwindow[275] :=  2.18868e-04   * S2H;
  enwindow[276] :=  1.01566e-04   * S2H;
  enwindow[277] :=  1.3828e-05    * S2H;
  { Next 4: 1/2.384e-6 scaled }
  enwindow[278] :=  3.0526638e-02 * INV;
  enwindow[279] :=  4.638195e-03  * INV;
  enwindow[280] :=  7.47204e-04   * INV;
  enwindow[281] :=  4.9591e-05    * INV;
  { Next 3: }
  enwindow[282] :=  4.756451e-03  * INV;
  enwindow[283] :=  2.1458e-05    * INV;
  enwindow[284] := -6.9618e-05    * INV;
  { [285..287] not accessed, zero-fill }
  enwindow[285] := 0;
  enwindow[286] := 0;
  enwindow[287] := 0;
end;

procedure window_subband(x1: PSample; var a: array of TFloat);
var
  i, j: Integer;
  s, t, u, v, w, xr: TFloat;
  wp: PSingle;
  x2: PSample;
begin
  wp := @enwindow[10];
  x2 := x1;
  Dec(x2, 62);  { x1 + (238 - 14 - 286) }

  for i := -15 to -1 do
  begin
    w := wp[-10]; s := x2[-224] * w; t := x1[224] * w;
    w := wp[-9];  s += x2[-160] * w; t += x1[160] * w;
    w := wp[-8];  s += x2[-96]  * w; t += x1[96]  * w;
    w := wp[-7];  s += x2[-32]  * w; t += x1[32]  * w;
    w := wp[-6];  s += x2[32]   * w; t += x1[-32] * w;
    w := wp[-5];  s += x2[96]   * w; t += x1[-96] * w;
    w := wp[-4];  s += x2[160]  * w; t += x1[-160] * w;
    w := wp[-3];  s += x2[224]  * w; t += x1[-224] * w;
    w := wp[-2];  s += x1[-256] * w; t -= x2[256]  * w;
    w := wp[-1];  s += x1[-192] * w; t -= x2[192]  * w;
    w := wp[0];   s += x1[-128] * w; t -= x2[128]  * w;
    w := wp[1];   s += x1[-64]  * w; t -= x2[64]   * w;
    w := wp[2];   s += x1[0]    * w; t -= x2[0]    * w;
    w := wp[3];   s += x1[64]   * w; t -= x2[-64]  * w;
    w := wp[4];   s += x1[128]  * w; t -= x2[-128] * w;
    w := wp[5];   s += x1[192]  * w; t -= x2[-192] * w;
    s := s * wp[6];
    w := t - s;
    a[30 + i * 2] := t + s;
    a[31 + i * 2] := wp[7] * w;
    Inc(wp, 18);
    Dec(x1);
    Inc(x2);
  end;

  { i = 0 final butterfly }
  t := x1[-16] * wp[-10];
  s := x1[-32] * wp[-2];
  t += (x1[-48] - x1[16])   * wp[-9];
  s += x1[-96]  * wp[-1];
  t += (x1[-80] + x1[48])   * wp[-8];
  s += x1[-160] * wp[0];
  t += (x1[-112] - x1[80])  * wp[-7];
  s += x1[-224] * wp[1];
  t += (x1[-144] + x1[112]) * wp[-6];
  s -= x1[32]  * wp[2];
  t += (x1[-176] - x1[144]) * wp[-5];
  s -= x1[96]  * wp[3];
  t += (x1[-208] + x1[176]) * wp[-4];
  s -= x1[160] * wp[4];
  t += (x1[-240] - x1[208]) * wp[-3];
  s -= x1[224];

  u := s - t;
  v := s + t;
  t := a[14];
  s := a[15] - t;
  a[31] := v + t;
  a[30] := u + s;
  a[15] := u - s;
  a[14] := v - t;

  { Butterfly reduction }
  xr := a[28] - a[0];  a[0] += a[28];  a[28] := xr * wp[-2*18+7];
  xr := a[29] - a[1];  a[1] += a[29];  a[29] := xr * wp[-2*18+7];
  xr := a[26] - a[2];  a[2] += a[26];  a[26] := xr * wp[-4*18+7];
  xr := a[27] - a[3];  a[3] += a[27];  a[27] := xr * wp[-4*18+7];
  xr := a[24] - a[4];  a[4] += a[24];  a[24] := xr * wp[-6*18+7];
  xr := a[25] - a[5];  a[5] += a[25];  a[25] := xr * wp[-6*18+7];

  xr := a[22] - a[6];  a[6] += a[22];  a[22] := xr * LAME_SQRT2;
  xr := a[23] - a[7];  a[7] += a[23];  a[23] := xr * LAME_SQRT2 - a[7];
  a[7] -= a[6];  a[22] -= a[7];  a[23] -= a[22];

  xr := a[6]; a[6] := a[31] - xr; a[31] := a[31] + xr;
  xr := a[7]; a[7] := a[30] - xr; a[30] := a[30] + xr;
  xr := a[22]; a[22] := a[15] - xr; a[15] := a[15] + xr;
  xr := a[23]; a[23] := a[14] - xr; a[14] := a[14] + xr;

  xr := a[20] - a[8];  a[8] += a[20];  a[20] := xr * wp[-10*18+7];
  xr := a[21] - a[9];  a[9] += a[21];  a[21] := xr * wp[-10*18+7];
  xr := a[18] - a[10]; a[10] += a[18]; a[18] := xr * wp[-12*18+7];
  xr := a[19] - a[11]; a[11] += a[19]; a[19] := xr * wp[-12*18+7];
  xr := a[16] - a[12]; a[12] += a[16]; a[16] := xr * wp[-14*18+7];
  xr := a[17] - a[13]; a[13] += a[17]; a[17] := xr * wp[-14*18+7];

  xr := -a[20] + a[24]; a[20] += a[24]; a[24] := xr * wp[-12*18+7];
  xr := -a[21] + a[25]; a[21] += a[25]; a[25] := xr * wp[-12*18+7];
  xr := a[4] - a[8];   a[4] += a[8];   a[8]  := xr * wp[-12*18+7];
  xr := a[5] - a[9];   a[5] += a[9];   a[9]  := xr * wp[-12*18+7];
  xr := a[0] - a[12];  a[0] += a[12];  a[12] := xr * wp[-4*18+7];
  xr := a[1] - a[13];  a[1] += a[13];  a[13] := xr * wp[-4*18+7];
  xr := a[16] - a[28]; a[16] += a[28]; a[28] := xr * wp[-4*18+7];
  xr := -a[17] + a[29]; a[17] += a[29]; a[29] := xr * wp[-4*18+7];

  xr := LAME_SQRT2 * (a[2] - a[10]);  a[2] += a[10];  a[10] := xr;
  xr := LAME_SQRT2 * (a[3] - a[11]);  a[3] += a[11];  a[11] := xr;
  xr := LAME_SQRT2 * (-a[18] + a[26]); a[18] += a[26]; a[26] := xr - a[18];
  xr := LAME_SQRT2 * (-a[19] + a[27]); a[19] += a[27]; a[27] := xr - a[19];

  xr := a[2];  a[19] -= a[3];  a[3] -= xr;  a[2] := a[31] - xr; a[31] += xr;
  xr := a[3];  a[11] -= a[19]; a[18] -= xr; a[3] := a[30] - xr; a[30] += xr;
  xr := a[18]; a[27] -= a[11]; a[19] -= xr; a[18] := a[15] - xr; a[15] += xr;
  xr := a[19]; a[10] -= xr;   a[19] := a[14] - xr; a[14] += xr;
  xr := a[10]; a[11] -= xr;   a[10] := a[23] - xr; a[23] += xr;
  xr := a[11]; a[26] -= xr;   a[11] := a[22] - xr; a[22] += xr;
  xr := a[26]; a[27] -= xr;   a[26] := a[7] - xr;  a[7] += xr;
  xr := a[27]; a[27] := a[6] - xr; a[6] += xr;

  xr := LAME_SQRT2 * (a[0] - a[4]);   a[0] += a[4];  a[4] := xr;
  xr := LAME_SQRT2 * (a[1] - a[5]);   a[1] += a[5];  a[5] := xr;
  xr := LAME_SQRT2 * (a[16] - a[20]); a[16] += a[20]; a[20] := xr;
  xr := LAME_SQRT2 * (a[17] - a[21]); a[17] += a[21]; a[21] := xr;
  xr := -LAME_SQRT2 * (a[8] - a[12]); a[8] += a[12]; a[12] := xr - a[8];
  xr := -LAME_SQRT2 * (a[9] - a[13]); a[9] += a[13]; a[13] := xr - a[9];
  xr := -LAME_SQRT2 * (a[25] - a[29]); a[25] += a[29]; a[29] := xr - a[25];
  xr := -LAME_SQRT2 * (a[24] + a[28]); a[24] -= a[28]; a[28] := xr - a[24];

  xr := a[24] - a[16]; a[24] := xr; xr := a[20] - xr; a[20] := xr; xr := a[28] - xr; a[28] := xr;
  xr := a[25] - a[17]; a[25] := xr; xr := a[21] - xr; a[21] := xr; xr := a[29] - xr; a[29] := xr;

  xr:=a[17]-a[1];   a[17]:=xr; xr:=a[9]-xr;  a[9]:=xr;  xr:=a[25]-xr; a[25]:=xr;
  xr:=a[5]-xr;      a[5]:=xr;  xr:=a[21]-xr; a[21]:=xr; xr:=a[13]-xr; a[13]:=xr;
  xr:=a[29]-xr;     a[29]:=xr;

  xr:=a[1]-a[0];    a[1]:=xr;  xr:=a[16]-xr; a[16]:=xr; xr:=a[17]-xr; a[17]:=xr;
  xr:=a[8]-xr;      a[8]:=xr;  xr:=a[9]-xr;  a[9]:=xr;  xr:=a[24]-xr; a[24]:=xr;
  xr:=a[25]-xr;     a[25]:=xr; xr:=a[4]-xr;  a[4]:=xr;  xr:=a[5]-xr;  a[5]:=xr;
  xr:=a[20]-xr;     a[20]:=xr; xr:=a[21]-xr; a[21]:=xr; xr:=a[12]-xr; a[12]:=xr;
  xr:=a[13]-xr;     a[13]:=xr; xr:=a[28]-xr; a[28]:=xr; xr:=a[29]-xr; a[29]:=xr;

  xr:=a[0]; a[0]+=a[31]; a[31]-=xr; xr:=a[1]; a[1]+=a[30]; a[30]-=xr;
  xr:=a[16]; a[16]+=a[15]; a[15]-=xr; xr:=a[17]; a[17]+=a[14]; a[14]-=xr;
  xr:=a[8]; a[8]+=a[23]; a[23]-=xr; xr:=a[9]; a[9]+=a[22]; a[22]-=xr;
  xr:=a[24]; a[24]+=a[7]; a[7]-=xr; xr:=a[25]; a[25]+=a[6]; a[6]-=xr;
  xr:=a[4]; a[4]+=a[27]; a[27]-=xr; xr:=a[5]; a[5]+=a[26]; a[26]-=xr;
  xr:=a[20]; a[20]+=a[11]; a[11]-=xr; xr:=a[21]; a[21]+=a[10]; a[10]-=xr;
  xr:=a[12]; a[12]+=a[19]; a[19]-=xr; xr:=a[13]; a[13]+=a[18]; a[18]-=xr;
  xr:=a[28]; a[28]+=a[3]; a[3]-=xr; xr:=a[29]; a[29]+=a[2]; a[2]-=xr;
end;

procedure mdct_short(inout: PSingle);
var
  l: Integer;
  tc0, tc1, tc2, ts0, ts1, ts2: TFloat;
begin
  { win[SHORT_TYPE][0..2] }
  for l := 0 to 2 do
  begin
    ts0 := inout[2*3] * win[SHORT_TYPE][0] - inout[5*3];
    tc0 := inout[0*3] * win[SHORT_TYPE][2] - inout[3*3];
    tc1 := ts0 + tc0;
    tc2 := ts0 - tc0;
    ts0 := inout[5*3] * win[SHORT_TYPE][0] + inout[2*3];
    tc0 := inout[3*3] * win[SHORT_TYPE][2] + inout[0*3];
    ts1 :=  ts0 + tc0;
    ts2 := -ts0 + tc0;

    tc0 := (inout[1*3] * win[SHORT_TYPE][1] - inout[4*3]) * 2.069978111953089e-11;
    ts0 := (inout[4*3] * win[SHORT_TYPE][1] + inout[1*3]) * 2.069978111953089e-11;

    inout[3*0] := tc1 * 1.907525191737280e-11 + tc0;
    inout[3*5] := -ts1 * 1.907525191737280e-11 + ts0;

    tc2 := tc2 * 0.86602540378443870761 * 1.907525191737281e-11;
    ts1 := ts1 * 0.5 * 1.907525191737281e-11 + ts0;
    inout[3*1] := tc2 - ts1;
    inout[3*2] := tc2 + ts1;

    tc1 := tc1 * 0.5 * 1.907525191737281e-11 - tc0;
    ts2 := ts2 * 0.86602540378443870761 * 1.907525191737281e-11;
    inout[3*3] := tc1 + ts2;
    inout[3*4] := tc1 - ts2;

    Inc(inout);
  end;
end;

procedure mdct_long(out_: PSingle; const in_: PSingle);
{ cx = win[SHORT_TYPE]+12, i.e. win[SHORT_TYPE][12..19] }
var
  ct, st: TFloat;
  tc1, tc2, tc3, tc4, ts5, ts6, ts7, ts8: TFloat;
  ts1, ts2, ts3, ts4, tc5, tc6, tc7, tc8: TFloat;
const
  cx0 = 0.98480775301220802032;
  cx1 = 0.64278760968653936292;
  cx2 = 0.34202014332566882393;
  cx3 = 0.93969262078590842791;
  cx4 = -0.17364817766693030343;
  cx5 = -0.76604444311897790243;
  cx6 = 0.86602540378443870761;
  cx7 = 0.500000000000000;
begin
  { Part 1 }
  tc1 := in_[17] - in_[9];
  tc3 := in_[15] - in_[11];
  tc4 := in_[14] - in_[12];
  ts5 := in_[0] + in_[8];
  ts6 := in_[1] + in_[7];
  ts7 := in_[2] + in_[6];
  ts8 := in_[3] + in_[5];

  out_[17] := (ts5 + ts7 - ts8) - (ts6 - in_[4]);
  st := (ts5 + ts7 - ts8) * cx7 + (ts6 - in_[4]);
  ct := (tc1 - tc3 - tc4) * cx6;
  out_[5] := ct + st;
  out_[6] := ct - st;

  tc2 := (in_[16] - in_[10]) * cx6;
  ts6 := ts6 * cx7 + in_[4];
  ct := tc1*cx0 + tc2 + tc3*cx1 + tc4*cx2;
  st := -ts5*cx4 + ts6 - ts7*cx5 + ts8*cx3;
  out_[1] := ct + st;
  out_[2] := ct - st;

  ct := tc1*cx1 - tc2 - tc3*cx2 + tc4*cx0;
  st := -ts5*cx5 + ts6 - ts7*cx3 + ts8*cx4;
  out_[9] := ct + st;
  out_[10] := ct - st;

  ct := tc1*cx2 - tc2 + tc3*cx0 - tc4*cx1;
  st := ts5*cx3 - ts6 + ts7*cx4 - ts8*cx5;
  out_[13] := ct + st;
  out_[14] := ct - st;

  { Part 2 }
  ts1 := in_[8] - in_[0];
  ts3 := in_[6] - in_[2];
  ts4 := in_[5] - in_[3];
  tc5 := in_[17] + in_[9];
  tc6 := in_[16] + in_[10];
  tc7 := in_[15] + in_[11];
  tc8 := in_[14] + in_[12];

  out_[0] := (tc5 + tc7 + tc8) + (tc6 + in_[13]);
  ct := (tc5 + tc7 + tc8) * cx7 - (tc6 + in_[13]);
  st := (ts1 - ts3 + ts4) * cx6;
  out_[11] := ct + st;
  out_[12] := ct - st;

  ts2 := (in_[7] - in_[1]) * cx6;
  tc6 := in_[13] - tc6 * cx7;
  ct := tc5*cx3 - tc6 + tc7*cx4 + tc8*cx5;
  st := ts1*cx2 + ts2 + ts3*cx0 + ts4*cx1;
  out_[3] := ct + st;
  out_[4] := ct - st;

  ct := -tc5*cx5 + tc6 - tc7*cx3 - tc8*cx4;
  st := ts1*cx1 + ts2 - ts3*cx2 - ts4*cx0;
  out_[7] := ct + st;
  out_[8] := ct - st;

  ct := -tc5*cx4 + tc6 - tc7*cx5 - tc8*cx3;
  st := ts1*cx0 - ts2 + ts3*cx1 - ts4*cx2;
  out_[15] := ct + st;
  out_[16] := ct - st;
end;

procedure mdct_sub48(gfc: PLameInternalFlags;
                     const w0: PSample; const w1: PSample);
var
  ch, gr, band, k: Integer;
  gi: PGrInfo;
  mdct_enc: PSingle;
  wk: PSample;
  subband_buf: array[0..SBLIMIT - 1] of TFloat;  { local copy of a[] }
  a_ptr: PSingle;
  cfg: ^TSessionConfig_t;
  esv: ^TEncStateVar_t;
  band0: PSingle;
  band1: PSingle;
  block_type: Integer;
  kk: Integer;
  work: array[0..17] of TFloat;
  a_, b_: TFloat;
  tantab_l_: PSingle;
  ca_: PSingle;
  cs_: PSingle;
  bu, bd, w: TFloat;
begin
  cfg := @gfc^.cfg;
  esv := @gfc^.sv_enc;

  { tantab_l = win[SHORT_TYPE][3], cx = [12], ca = [20], cs = [28] }
  tantab_l_ := @win[SHORT_TYPE][3];
  ca_        := @win[SHORT_TYPE][20];
  cs_        := @win[SHORT_TYPE][28];

  wk := w0;
  Inc(wk, 286);

  for ch := 0 to cfg^.channels_out - 1 do
  begin
    for gr := 0 to cfg^.mode_gr - 1 do
    begin
      gi       := @gfc^.l3_side.tt[gr][ch];
      mdct_enc := @gi^.xr[0];

      for k := 0 to 18 div 2 - 1 do
      begin
        window_subband(wk, esv^.sb_sample[ch][1-gr][k*2]);
        window_subband(PSingle(wk) + 32, esv^.sb_sample[ch][1-gr][k*2 + 1]);
        Inc(wk, 64);
        { Compensate for inversion in the analysis filter }
        for band := 1 to 31 do
          if (band and 1) = 1 then
            esv^.sb_sample[ch][1-gr][k*2+1][band] *= -1.0;
      end;

      { Perform MDCT of 18 prev + 18 current subband samples }
      for band := 0 to 31 do
      begin
        block_type := gi^.block_type;
        if (gi^.mixed_block_flag <> 0) and (band < 2) then
          block_type := 0;

        { band0 = sb_sample[ch][gr][band_reordered] }
        { band1 = sb_sample[ch][1-gr][band_reordered] }
        band0 := @esv^.sb_sample[ch][gr][0][order[band]];
        band1 := @esv^.sb_sample[ch][1-gr][0][order[band]];

        if esv^.amp_filter[band] < 1e-12 then
          FillChar(mdct_enc^, 18 * SizeOf(TFloat), 0)
        else
        begin
          if esv^.amp_filter[band] < 1.0 then
            for k := 0 to 17 do
              PSingleArray(band1)^[k * 32] *= esv^.amp_filter[band];

          if block_type = SHORT_TYPE then
          begin
            for kk := -NS div 4 to -1 do
            begin
              w := win[SHORT_TYPE][kk + 3];
              mdct_enc[kk*3 + 9]  := PSingleArray(band0)^[(9+kk)*32] * w
                                   - PSingleArray(band0)^[(8-kk)*32];
              mdct_enc[kk*3 + 18] := PSingleArray(band0)^[(14-kk)*32] * w
                                   + PSingleArray(band0)^[(15+kk)*32];
              mdct_enc[kk*3 + 10] := PSingleArray(band0)^[(15+kk)*32] * w
                                   - PSingleArray(band0)^[(14-kk)*32];
              mdct_enc[kk*3 + 19] := PSingleArray(band1)^[(2-kk)*32] * w
                                   + PSingleArray(band1)^[(3+kk)*32];
              mdct_enc[kk*3 + 11] := PSingleArray(band1)^[(3+kk)*32] * w
                                   - PSingleArray(band1)^[(2-kk)*32];
              mdct_enc[kk*3 + 20] := PSingleArray(band1)^[(8-kk)*32] * w
                                   + PSingleArray(band1)^[(9+kk)*32];
            end;
            mdct_short(mdct_enc);
          end
          else
          begin
            for kk := -NL div 4 to -1 do
            begin
              a_ := win[block_type][kk+27] * PSingleArray(band1)^[(kk+9)*32]
                  + win[block_type][kk+36] * PSingleArray(band1)^[(8-kk)*32];
              b_ := win[block_type][kk+9]  * PSingleArray(band0)^[(kk+9)*32]
                  - win[block_type][kk+18] * PSingleArray(band0)^[(8-kk)*32];
              work[kk+9]  := a_ - b_ * tantab_l_[kk+9];
              work[kk+18] := a_ * tantab_l_[kk+9] + b_;
            end;
            mdct_long(mdct_enc, @work[0]);
          end;
        end;

        { Aliasing reduction butterfly (not for SHORT_TYPE or band=0) }
        if (block_type <> SHORT_TYPE) and (band <> 0) then
        begin
          for k := 7 downto 0 do
          begin
            bu := mdct_enc[k] * ca_[k] + mdct_enc[-1-k] * cs_[k];
            bd := mdct_enc[k] * cs_[k] - mdct_enc[-1-k] * ca_[k];
            mdct_enc[-1-k] := bu;
            mdct_enc[k]    := bd;
          end;
        end;

        Inc(mdct_enc, 18);
      end;
    end;

    wk := w1;
    Inc(wk, 286);

    if cfg^.mode_gr = 1 then
      Move(esv^.sb_sample[ch][1], esv^.sb_sample[ch][0],
           576 * SizeOf(TFloat));
  end;
end;

initialization
  init_enwindow;

end.
