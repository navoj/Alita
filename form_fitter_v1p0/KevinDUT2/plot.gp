if (strstrt(GPVAL_TERMINALS, "pngcairo") > 0) { set terminal pngcairo size 1100,600 font "Arial,10" } else { set terminal png size 1100,600 }
set datafile missing "nan"
set grid
set key top right
set output "KevinDUT2/fit.png"
set title "form_fit: y = 30115.664 - 259.95988 * sqrt((sin(sqrt(sqrt(sqrt(abs(x))))) / (1.8592 / x))) + 15340.137 * (sqrt(sqrt(x)) / (0.00..." noenhanced
set xlabel "x"
set ylabel "y"
plot "KevinDUT2/curve.dat" using 1:2 with lines lw 2 lc rgb "#d62728" title "evolved function", \
     "KevinDUT2/data.dat" using 1:2 with points pt 7 ps 0.8 lc rgb "#1f77b4" title "data"
set output "KevinDUT2/convergence.png"
set title "Convergence (normalised MSE)"
set xlabel "generation"
set ylabel "NMSE"
set logscale y
set xrange [0:150]
set format y "%.0e"
plot "KevinDUT2/history.txt" using 1:2 with lines lw 2 lc rgb "#d62728" title "best", \
     "KevinDUT2/history.txt" using 1:3 with lines lw 2 lc rgb "#7f7f7f" title "population median"
