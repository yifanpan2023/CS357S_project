
if [ -f "xSanity/xSanity.sv" ] && [ -f "./src/topsim.sv" ]; then
    { head -n -1 "./src/topsim.sv"; cat "./src/macro.sv"; cat "xSanity/xSanity.sv" ; echo "" ; tail -n 1 "./src/topsim.sv"; } > "xSanity/xSanity_top.sv" #"/_top.sv"
else 
    echo "[RUN_JG] no property at xSanity/xSanity.sv is found or no ./src/topsim.sv"
    exit 0
fi

