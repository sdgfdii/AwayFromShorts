package com.afs.guard;

import android.app.job.JobParameters;
import android.app.job.JobService;

/** 15 分钟兜底：闹钟被系统掐掉、时区变了、手动改了时间，都靠它拉回来。 */
public class GuardJob extends JobService {

    @Override
    public boolean onStartJob(JobParameters params) {
        Guard.apply(this);
        Guard.schedule(this);
        return false;
    }

    @Override
    public boolean onStopJob(JobParameters params) {
        return true;
    }
}
