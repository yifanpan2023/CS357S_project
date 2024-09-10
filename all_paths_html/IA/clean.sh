for d in $(find . -type d)
do
  nm=$(basename $d)
  if [[ $nm == *"III" ]];
  then
    continue
  fi
  if [[ $nm == *"nonisograph" ]];
  then
    continue
  fi

  if [[ ${nm} != "xSummarize" ]]; 
  then
     #echo $d 
     echo "rm -rf $d"
  fi
done
