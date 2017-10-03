<h3>GCALVIEW</h3>
<ul>
  <u><b>GCALVIEW - Google Calendar Viewer</b></u>
  <br><br>
  <b>Installation:</b>
  <ul>
    <li>sudo apt-get install gcalcli</li>
    <li>sudo pip install gcalcli</li>
    <li>sudo su - fhem (be sure that the user is really activated!)</li>
    <li>If it is not possible to open a bash try the following:</li>
    <ul>
        <li>sudo nano /etc/passwd</li>
        <li>search for fhem and replace /bin/false with /bin/bash</li>
    </ul>
    <li>add the new update site: update add http://<i></i>raw.githubusercontent.com/mumpitzstuff/fhem-GCALVIEW/master/controls_gcalview.txt</li>
    <li>run the update and wait until finished: update all</li>
    <li>restart fhem: shutdown restart</li>
    <li>define a new device: define &lt;name&gt; GCALVIEW &lt;timeout&gt;</li>
  </ul>
</ul>
