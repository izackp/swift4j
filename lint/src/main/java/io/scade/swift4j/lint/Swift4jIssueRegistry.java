package io.scade.swift4j.lint;

import com.android.tools.lint.client.api.IssueRegistry;
import com.android.tools.lint.client.api.Vendor;
import com.android.tools.lint.detector.api.ApiKt;
import com.android.tools.lint.detector.api.Issue;

import java.util.Collections;
import java.util.List;

public class Swift4jIssueRegistry extends IssueRegistry {

  @Override
  public List<Issue> getIssues() {
    return Collections.singletonList(DiscardedSwiftWriteDetector.ISSUE);
  }

  @Override
  public int getApi() {
    return ApiKt.CURRENT_API;
  }

  @Override
  public Vendor getVendor() {
    return new Vendor("swift4j", "swift4j", null, null);
  }
}
