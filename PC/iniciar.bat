@echo off
set /p IP=Digite o IP que aparece no app Drone VR do iPhone: 
python pc_stream.py --ip %IP%
pause
