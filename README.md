<h3>GCALVIEW</h3>
<ul>
  <u><b>GCALVIEW - Google Calendar Viewer</b></u>
  <br><br>
  <b>Installation:</b>
  <ul>
    <li>sudo apt-get install gcalcli<br>
    sudo pip install gcalcli</li>
    <li>Test if at least version 3.4.0 is installed with gcalcli --version. Don't proceed if you have an older version! Try some alternative installation methods first.</li>
    <li>sudo su - fhem (be sure that the user is really activated!)</li>
    <li>If it is not possible to open a bash, try the following:</li>
    <ul>
        <li>sudo nano /etc/passwd</li>
        <li>search for fhem and replace /bin/false with /bin/bash (just needed temporary and can be reverted afterwards)</li>
    </ul>
    <li>gcalcli list --noauth_local_webserver
    Copy the URL into a browser and start it. Accept the connection to your Google Calendar and copy the OAuth token. Enter the token in your fhem console window and press enter.</li>
    <li>gcalcli list
    First check if you can see a list of your Google calendars now.</li>
    <li>A new hidden file .calcli_oauth should exist in your fhem directory. Do not proceed if it does not exist. Try to do the following:<br>
    gcalcli list --noauth_local_webserver --configFolder /opt/fhem<br>
    Copy the url and do the same like before. Now check again if you can get a list of calendars:<br>
    gcalcli list --configFolder /opt/fhem<br>
    Proceed if it was successful.</li>
    <li>Be sure that you revert the change in /etc/passwd for security reasons!
    Enter exit to leave the bash of user fhem and revert the change in /etc/passwd again.</li>   
    <li>add the new update site: update add http://<i></i>raw.githubusercontent.com/mumpitzstuff/fhem-GCALVIEW/master/controls_gcalview.txt</li>
    <li>run the update and wait until finished: update all</li>
    <li>restart fhem: shutdown restart</li>
    <li>Test if gcalcli can be called from fhem. Just enter and start the following command and check if you can get a list of your Google calendars:<br>
    {qx(gcalcli list);;}</li>
    <li>define a new device: define &lt;name&gt; GCALVIEW &lt;timeout&gt;</li>
    <li>Be sure that you set the configFilder attribute if it was required in the previous installation procedure (/opt/fhem)!</li> 
  </ul><br><br>
  <b>Alternative Installation:</b>
  <ul>
    <li>git clone https://github.com/insanum/gcalcli.git<br>
    cd gcalcli<br>
    python setup.py install</li>
    <li>Download the right deb file for your system from: https://pkgs.org/download/gcalcli and install it:<br>
    sudo dpkg -i &lt;name of file&gt;.deb</li>    
  </ul>
</ul>
