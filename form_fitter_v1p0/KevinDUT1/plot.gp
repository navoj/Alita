if (strstrt(GPVAL_TERMINALS, "pngcairo") > 0) { set terminal pngcairo size 1100,600 font "Arial,10" } else { set terminal png size 1100,600 }
set datafile missing "nan"
set grid
set key top right
set output "KevinDUT1/fit.png"
set title "form_fit: y = 38.460981 - 53.459596 * sqrt((sin(log(log(log(x)))) + (exp(log(x)) / x))) + 0.0072420788 * log((2.09331e+06 / x))..." noenhanced
set xlabel "x"
set ylabel "y"
plot "KevinDUT1/curve.dat" using 1:2 with lines lw 2 lc rgb "#d62728" title "evolved function", \
     "KevinDUT1/data.dat" using 1:2 with points pt 7 ps 0.8 lc rgb "#1f77b4" title "data"
set output "KevinDUT1/convergence.png"
set title "Convergence (normalised MSE)"
set xlabel "generation"
set ylabel "NMSE"
set logscale y
set xrange [0:150]
set format y "%.0e"
plot "KevinDUT1/history.txt" using 1:2 with lines lw 2 lc rgb "#d62728" title "best", \
     "KevinDUT1/history.txt" using 1:3 with lines lw 2 lc rgb "#7f7f7f" title "population median"
